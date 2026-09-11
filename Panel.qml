import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Video to DVD panel: pick a video, convert to a DVD-Video ISO, wait for a
// blank disc, burn, eject, and notify. One primary action; cancel stops the
// whole process group. First-run setup installs Arch packages and DVD drive
// permission via a terminal (sudo password).
Panel {
  id: root
  moduleName: "io.github.ruegen.video-to-dvd"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var settings: ({})
  property bool applyingSettings: false
  readonly property var barIdentity: hostWidget || root

  I18n { id: i18n }

  function t(key) {
    switch (arguments.length) {
    case 0: return ""
    case 1: return i18n.t(key)
    case 2: return i18n.t(key, arguments[1])
    case 3: return i18n.t(key, arguments[1], arguments[2])
    default: return i18n.t(key, arguments[1], arguments[2], arguments[3])
    }
  }

  property string tvStandard: "PAL"
  property string helperPath: Qt.resolvedUrl("oma-dvd").toString().replace("file://", "")
  property string inputPath: ""
  property string inputName: ""
  property string outputIso: ""
  property int progressPct: 0
  property string statusText: ""
  property bool busy: false
  property bool converted: false
  property bool userCancelled: false
  property bool waitNotified: false
  property bool jobHasError: false
  property int jobPgid: 0
  property string phase: "idle"

  property bool setupProbed: false
  property bool setupBusy: false
  property string setupKind: ""
  property string missingPkgs: ""
  property bool packagesReady: false
  property string driveStatus: "none"
  property string selectedDevice: ""
  property string discState: "unknown"
  property bool cursorActive: false
  property bool keyNav: false
  property bool burnConfirmOpen: false
  property int cursorRow: 0
  property int cursorCol: 0
  property string cursorId: ""

  onPackagesReadyChanged: root.applySetupStatus()
  onOpenedChanged: {
    if (root.opened) {
      root.probeSetup()
      root.cursorActive = true
      root.keyNav = false
      root.snapCursorToDefault()
      if (root.showWorkUi)
        root.pollBlank()
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    }
  }
  onPhaseChanged: root.clampCursor()
  onBusyChanged: root.clampCursor()
  onShowPackageSetupChanged: root.clampCursor()
  onShowDriveSetupChanged: root.clampCursor()
  onShowDoneUiChanged: root.clampCursor()
  onCanMakeDvdChanged: root.clampCursor()
  onShowDiscSpinChanged: root.clampCursor()

  readonly property int driveCount: driveModel.count
  readonly property bool showPackageSetup: root.setupProbed && !root.packagesReady
  readonly property bool showDriveSetup: root.setupProbed && root.packagesReady && root.driveStatus === "need-permission"
  readonly property bool showMainActions: root.packagesReady && !root.showDriveSetup
  readonly property bool showDoneUi: root.phase === "done"
  readonly property bool waitingToBurn: root.phase === "wait"
  readonly property bool showWorkUi: root.showMainActions && !root.showDoneUi
  readonly property bool discIsBlank: root.discState === "yes"
  readonly property bool canMakeDvd: !root.busy && root.showWorkUi && root.inputPath.length > 0
  readonly property bool showDiscSpin: root.busy && root.phase === "burn"
  property color themeGreen: "#9ece6a"
  readonly property color discColor: root.themeGreen

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  ListModel { id: driveModel }

  function open() { root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }
  function closeForPopoutSwitch() { root.controller.hide() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function plainText(s) {
    return String(s == null ? "" : s)
      .replace(/[&<>]/g, "")
      .replace(/[\u0000-\u001f\u007f\u0080-\u009f]/g, "")
      .substring(0, 240)
  }

  function isOpticalDevice(path) {
    return /^\/dev\/sr[0-9]+$/.test(String(path || ""))
  }

  function deriveOutputIso(path) {
    return path.replace(/\.[^./]+$/, "") + ".iso"
  }

  function notify(title, body, sound) {
    var args = [root.helperPath, "notify", root.plainText(title), root.plainText(body || "")]
    if (sound)
      args.push(sound)
    notifyProc.exec(args)
  }

  function resetIdle(status) {
    root.busy = false
    root.phase = "idle"
    root.jobPgid = 0
    root.burnConfirmOpen = false
    if (status !== undefined)
      root.statusText = status
  }

  function enterDone() {
    waitTimer.stop()
    if (blankProc.running)
      blankProc.running = false
    root.busy = false
    root.converted = true
    root.progressPct = 100
    root.jobPgid = 0
    root.jobHasError = false
    root.phase = "done"
    root.statusText = root.t("done.title")
  }

  function makeAnother() {
    root.inputPath = ""
    root.inputName = ""
    root.outputIso = ""
    root.converted = false
    root.progressPct = 0
    root.userCancelled = false
    root.waitNotified = false
    root.jobHasError = false
    root.jobPgid = 0
    root.busy = false
    root.phase = "idle"
    root.statusText = root.t("status.idle")
  }

  function translateDriveLabel(label) {
    if (label.indexOf("drive.") !== 0)
      return label
    var space = label.indexOf(" ")
    if (space < 0)
      return root.t(label)
    return root.t(label.substring(0, space)) + label.substring(space)
  }

  function errorText(err) {
    if (!err)
      return ""
    var key = "error." + err
    var tr = root.t(key)
    if (tr !== key)
      return tr
    return err
  }

  function translateProgress(payload) {
    var bits = payload.split("|")
    var token = bits[0]
    if (token === "analyzing")
      return root.t("status.analyzing", bits[1] || "?", bits[2] || "", bits[3] || "")
    if (token === "encoding")
      return root.t("status.encoding")
    if (token === "encoding-pct")
      return root.t("status.encodingPct", bits[1] || "0")
    if (token === "encoding-finishing")
      return bits[1] ? root.t("status.encodingFinishingPct", bits[1]) : root.t("status.encodingFinishing")
    if (token === "encoding-eta") {
      var mins = bits[1] || ""
      var pct = bits[2] || ""
      if (pct) {
        if (mins === "1")
          return root.t("status.encodingEta1Pct", pct)
        return root.t("status.encodingEtaPct", pct, mins)
      }
      if (mins === "1")
        return root.t("status.encodingEta1")
      return root.t("status.encodingEta", mins)
    }
    if (token === "authoring")
      return root.t("status.authoring")
    if (token === "iso")
      return root.t("status.buildingIso")
    if (token === "done")
      return root.t("status.done")
    if (token === "unsupported-format")
      return root.t("status.unsupportedFormat", bits[1] || "")
    var mapped = root.t("status." + token)
    if (mapped !== "status." + token)
      return mapped
    return payload
  }

  function parseSetupLine(line) {
    if (line.indexOf("MISSING:") === 0) {
      root.missingPkgs = line.substring(8).trim()
      root.packagesReady = root.missingPkgs.length === 0
      return
    }
    if (line.indexOf("DRIVE:") === 0) {
      root.driveStatus = line.substring(6).trim()
      return
    }
    if (line.indexOf("DEV:") === 0) {
      var rest = line.substring(4)
      var bar = rest.indexOf("|")
      var path = bar >= 0 ? rest.substring(0, bar) : rest
      var label = bar >= 0 ? rest.substring(bar + 1) : rest
      if (path.length > 0 && root.isOpticalDevice(path))
        driveModel.append({ "devPath": path, "devLabel": root.plainText(root.translateDriveLabel(label)) })
    }
  }

  function parseSetupEvent(line) {
    if (line.indexOf("SETUP:OK") === 0) {
      setupPollTimer.stop()
      root.setupBusy = false
      root.probeSetup(true)
      return
    }
    if (line.indexOf("SETUP:INSTALLING") === 0 || line.indexOf("SETUP:DRIVE:") === 0) {
      if (!setupPollTimer.running)
        setupPollTimer.start()
      return
    }
    if (line.indexOf("SETUP:DONE") === 0) {
      root.probeSetup(true)
    }
  }

  function applySettingsFromHost() {
    root.applyingSettings = true
    var std = "PAL"
    if (root.settings && root.settings.tvStandard === "NTSC")
      std = "NTSC"
    root.tvStandard = std
    if (root.settings && root.isOpticalDevice(root.settings.selectedDevice))
      root.selectedDevice = String(root.settings.selectedDevice)
    root.applyingSettings = false
  }

  function persistChoices() {
    if (root.applyingSettings || !root.hostWidget)
      return
    var entry = { id: "io.github.ruegen.video-to-dvd" }
    var src = root.hostWidget.settings || {}
    for (var key in src) {
      if (key !== "id")
        entry[key] = src[key]
    }
    entry.tvStandard = root.tvStandard
    if (root.selectedDevice)
      entry.selectedDevice = root.selectedDevice
    root.hostWidget.settings = entry
    if (root.hostWidget.bar && root.hostWidget.bar.shell
        && typeof root.hostWidget.bar.shell.updateEntryInline === "function")
      root.hostWidget.bar.shell.updateEntryInline(root.hostWidget.moduleName, entry)
  }

  onSettingsChanged: root.applySettingsFromHost()
  onHostWidgetChanged: root.applySettingsFromHost()
  onTvStandardChanged: root.persistChoices()
  onSelectedDeviceChanged: {
    root.persistChoices()
    root.discState = "unknown"
    if (root.opened && root.showWorkUi)
      root.pollBlank()
  }

  function finalizeDrives() {
    var preferred = root.selectedDevice
    if (!preferred && root.settings && root.settings.selectedDevice)
      preferred = String(root.settings.selectedDevice)
    var found = false
    var i
    for (i = 0; i < driveModel.count; i++) {
      if (driveModel.get(i).devPath === preferred) {
        found = true
        break
      }
    }
    if (found && root.isOpticalDevice(preferred))
      root.selectedDevice = preferred
    else
      root.selectedDevice = (driveModel.count > 0 && root.isOpticalDevice(driveModel.get(0).devPath))
        ? driveModel.get(0).devPath : ""
  }

  function clearSetupBusy() {
    root.setupBusy = false
    root.setupKind = ""
    setupPollTimer.stop()
  }

  function applySetupStatus() {
    if (root.busy || root.phase === "done") return

    if (root.setupBusy && root.setupKind === "packages" && root.packagesReady)
      root.clearSetupBusy()
    if (root.setupBusy && root.setupKind === "drive" && root.driveStatus !== "need-permission")
      root.clearSetupBusy()

    if (!root.packagesReady) {
      root.statusText = (root.setupBusy && root.setupKind === "packages")
        ? root.t("status.installingPackages")
        : root.t("status.installPackages")
      return
    }
    if (root.driveStatus === "need-permission") {
      root.statusText = (root.setupBusy && root.setupKind === "drive")
        ? root.t("status.allowingBurning")
        : root.t("status.allowBurning")
      return
    }
    if (root.driveStatus === "none") {
      root.statusText = root.t("status.noDrive")
      return
    }
    root.statusText = root.inputPath ? root.t("status.ready") : root.t("status.idle")
  }

  function discStatusText() {
    if (root.discState === "yes")
      return root.t("status.ready")
    if (root.discState === "too_small")
      return root.t("status.discTooSmall")
    if (root.discState === "no")
      return root.t("status.discNotBlank")
    return root.t("status.insertBlank")
  }

  function probeSetup(force) {
    if (root.setupBusy && !force) return
    if (checkSetupProc.running) {
      if (force) return
      checkSetupProc.running = false
    }
    driveModel.clear()
    checkSetupProc.command = [root.helperPath, "check-setup"]
    checkSetupProc.running = true
  }

  function installPackages() {
    if (root.setupBusy || root.packagesReady || root.busy) return
    root.setupKind = "packages"
    root.setupBusy = true
    root.statusText = root.t("status.installingPackages")
    setupPollTimer.start()
    setupProc.command = [root.helperPath, "install-packages"]
    setupProc.running = true
  }

  function allowDvdBurning() {
    if (root.setupBusy || root.driveStatus !== "need-permission" || root.busy) return
    root.setupKind = "drive"
    root.setupBusy = true
    root.statusText = root.t("status.allowingBurning")
    setupPollTimer.start()
    setupProc.command = [root.helperPath, "add-optical"]
    setupProc.running = true
  }

  Component.onCompleted: root.probeSetup()

  function stripFileUri(p) {
    if (p.indexOf("file://") === 0) {
      p = p.substring(7)
      if (p.indexOf("localhost/") === 0)
        p = p.substring(9)
      try { p = decodeURIComponent(p) } catch (e) {}
    }
    return p
  }

  Process {
    id: pickerProc
    command: ["omarchy-file-select", "--title", "Select video",
              "--extensions", "mp4 mkv mov avi webm m4v ts mts m2ts wmv flv"]
    stdout: SplitParser {
      onRead: function(line) {
        var p = root.plainText(root.stripFileUri(line.trim()))
        if (p.length === 0) return
        root.inputPath = p
        root.inputName = root.plainText(p.split("/").pop())
        root.outputIso = root.deriveOutputIso(p)
        root.converted = false
        root.progressPct = 0
        root.discState = "unknown"
        root.statusText = root.driveCount === 0 ? root.t("status.noDrive") : root.t("status.ready")
      }
    }
    onExited: function(code) {
      // Exit 1 = nothing picked (not an error).
      if (code > 1 && !root.busy)
        root.statusText = root.t("status.pickerFailed")
      if (root.canMakeDvd)
        root.setCursorTo("make")
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    }
  }
  function pickFile() {
    if (root.busy) return
    pickerProc.command = ["omarchy-file-select", "--title", root.t("picker.title"),
                          "--extensions", "mp4 mkv mov avi webm m4v ts mts m2ts wmv flv"]
    pickerProc.running = true
  }

  Process { id: notifyProc }
  Process { id: killerProc }


  Process {
    id: checkSetupProc
    command: [root.helperPath, "check-setup"]
    stdout: SplitParser {
      onRead: function(line) { root.parseSetupLine(line.trim()) }
    }
    onExited: function() {
      root.setupProbed = true
      root.finalizeDrives()
      root.applySetupStatus()
    }
  }

  Process {
    id: setupProc
    command: [root.helperPath, "install-packages"]
    stdout: SplitParser {
      onRead: function(line) { root.parseSetupEvent(line.trim()) }
    }
    onExited: function() {
      root.setupBusy = false
      root.setupKind = ""
      setupPollTimer.stop()
      root.probeSetup(true)
    }
  }

  Timer {
    id: setupPollTimer
    interval: 2000
    repeat: true
    onTriggered: {
      if (!root.setupBusy) {
        setupPollTimer.stop()
        return
      }
      root.probeSetup(true)
    }
  }

  function parseJobLine(line) {
    if (line.indexOf("PGID:") === 0) {
      var n = parseInt(line.substring(5))
      if (!isNaN(n)) root.jobPgid = n
      return true
    }
    return false
  }

  Process {
    id: convertProc
    environment: ["VIDEO_TO_DVD_STANDARD=" + root.tvStandard]
    command: [root.helperPath, "convert", root.inputPath, root.outputIso]
    stdout: SplitParser {
      onRead: function(line) {
        if (root.parseJobLine(line)) return
        if (line.indexOf("PROGRESS:") === 0) {
          var rest = line.substring(9)
          var colon = rest.indexOf(":")
          var pct = parseInt(colon >= 0 ? rest.substring(0, colon) : rest)
          var payload = colon >= 0 ? rest.substring(colon + 1) : ""
          if (!isNaN(pct)) root.progressPct = pct
          root.statusText = root.translateProgress(payload)
        } else if (line.indexOf("RESULT:OK:") === 0) {
          root.statusText = root.t("status.converted")
          root.converted = true
          if (!root.userCancelled) {
            if (root.driveCount === 0)
              root.resetIdle(root.t("status.noDrive"))
            else
              root.enterWaitForDisc()
          }
        } else if (line.indexOf("RESULT:ERROR:") === 0) {
          root.handleJobError(line.substring(13), root.t("notify.convertFailed.title"))
        }
      }
    }
    onExited: function(code) {
      root.onJobExited(code, "convert", root.t("notify.convertFailed.title"), root.t("status.convertFailed", code))
    }
  }

  function pollBlank() {
    if (root.showDiscSpin || (root.phase === "wait" && root.userCancelled))
      return
    if (root.phase !== "wait" && root.phase !== "idle")
      return
    if (blankProc.running)
      blankProc.running = false
    Qt.callLater(function() {
      if (root.showDiscSpin)
        return
      if (root.phase !== "wait" && root.phase !== "idle")
        return
      if (root.phase === "wait" && root.userCancelled)
        return
      blankProc.running = true
    })
  }

  function tryBurnNow() {
    if (root.phase !== "wait" || root.userCancelled)
      return
    root.statusText = root.t("status.checkingDrive")
    root.pollBlank()
  }

  function startBurn() {
    if (root.phase === "burn" || root.userCancelled)
      return
    waitTimer.stop()
    if (blankProc.running)
      blankProc.running = false
    root.phase = "burn"
    root.progressPct = 0
    root.statusText = root.t("status.burning")
    if (burnProc.running)
      burnProc.running = false
    Qt.callLater(function() {
      if (root.phase === "burn" && !root.userCancelled)
        burnProc.running = true
    })
  }

  Timer {
    id: waitTimer
    interval: 3000
    repeat: true
    onTriggered: {
      if (root.phase !== "wait" || root.userCancelled) {
        waitTimer.stop()
        return
      }
      root.pollBlank()
    }
  }

  Timer {
    id: discPollTimer
    interval: 2500
    repeat: true
    running: root.opened && root.showWorkUi && !root.showDiscSpin
             && (root.phase === "idle" || root.phase === "wait")
    onTriggered: root.pollBlank()
  }

  Process {
    id: blankProc
    command: root.outputIso.length > 0 && root.selectedDevice.length > 0
      ? [root.helperPath, "check-blank", root.selectedDevice, root.outputIso]
      : (root.selectedDevice.length > 0
          ? [root.helperPath, "check-blank", root.selectedDevice]
          : [root.helperPath, "check-blank"])
    stdout: SplitParser {
      onRead: function(line) {
        var tline = line.trim()
        if (tline === "BLANK:YES")
          root.discState = "yes"
        else if (tline === "BLANK:TOO_SMALL")
          root.discState = "too_small"
        else if (tline === "BLANK:NO")
          root.discState = "no"
        else
          root.discState = "none"

        if (root.phase !== "wait" || root.userCancelled)
          return
        if (tline === "BLANK:YES") {
          root.startBurn()
        } else if (tline === "BLANK:TOO_SMALL") {
          root.statusText = root.t("status.discTooSmall")
          if (!root.waitNotified) {
            root.waitNotified = true
            root.notify(root.t("notify.discTooSmall.title"), root.t("notify.discTooSmall.body"))
          }
        } else if (tline === "BLANK:NO") {
          root.statusText = root.t("status.discNotBlank")
          if (!root.waitNotified) {
            root.waitNotified = true
            root.notify(root.t("notify.insertBlank.title"), root.t("notify.insertBlank.body"))
          }
        } else {
          root.statusText = root.t("status.insertBlank")
          if (!root.waitNotified) {
            root.waitNotified = true
            root.notify(root.t("notify.waiting.title"), root.t("notify.waiting.body"))
          }
        }
      }
    }
  }

  Process {
    id: burnProc
    command: root.selectedDevice.length > 0
      ? [root.helperPath, "burn", root.outputIso, root.selectedDevice]
      : [root.helperPath, "burn", root.outputIso]
    stdout: SplitParser {
      onRead: function(line) {
        if (root.parseJobLine(line)) return
        if (line.indexOf("PROGRESS:BURN:") === 0) {
          var raw = line.substring(14)
          var m = raw.match(/\(\s*([0-9]+(?:\.[0-9]+)?)\s*%\)/)
          if (m) {
            var p = Math.round(parseFloat(m[1]))
            if (!isNaN(p)) root.progressPct = p
          }
          var shown = root.t("status.burning")
          if (root.progressPct > 0)
            shown = shown + " · " + root.progressPct + "%"
          root.statusText = shown
        } else if (line.indexOf("RESULT:BURNED:") === 0) {
          root.enterDone()
          root.notify(root.t("notify.burned.title"), root.t("notify.burned.body"))
        } else if (line.indexOf("RESULT:ERROR:") === 0) {
          root.handleJobError(line.substring(13), root.t("notify.burnFailed.title"))
        }
      }
    }
    onExited: function(code) {
      root.onJobExited(code, "burn", root.t("notify.burnFailed.title"), root.t("status.burnFailedExit", code))
    }
  }

  function handleJobError(err, failTitle) {
    if (root.userCancelled || err === "cancelled") {
      if (err === "cancelled" && !root.userCancelled) {
        root.userCancelled = true
        root.notify(root.t("notify.cancelled.title"), root.t("notify.cancelled.body"))
      }
      waitTimer.stop()
      root.resetIdle(root.t("status.cancelled"))
      return
    }
    waitTimer.stop()
    root.jobHasError = true
    root.resetIdle(root.t("status.error", root.errorText(err)))
    root.notify(failTitle, root.statusText)
  }

  function onJobExited(code, expectedPhase, failTitle, fallbackStatus) {
    if (root.userCancelled) {
      waitTimer.stop()
      root.resetIdle(root.t("status.cancelled"))
      return
    }
    if (code === 0) return
    if (root.phase !== expectedPhase) return
    waitTimer.stop()
    if (!root.jobHasError)
      root.statusText = fallbackStatus
    root.busy = false
    root.phase = "idle"
    root.jobPgid = 0
    root.notify(failTitle, root.statusText)
  }

  function enterWaitForDisc() {
    root.phase = "wait"
    root.busy = true
    root.waitNotified = false
    root.progressPct = 0
    root.statusText = root.t("status.insertBlank")
    waitTimer.start()
    root.pollBlank()
  }

  function startOneShot() {
    if (root.busy) return
    if (!root.packagesReady) { root.statusText = root.t("status.installPackagesFirst"); return }
    if (!root.inputPath) { root.statusText = root.t("status.selectFileFirst"); return }
    root.userCancelled = false
    root.waitNotified = false
    root.jobHasError = false
    root.jobPgid = 0
    root.busy = true
    root.converted = false
    root.progressPct = 0
    root.phase = "convert"
    root.statusText = root.t("status.starting")
    convertProc.running = true
  }

  function cancelAll() {
    if (!root.busy) return
    if (root.phase === "burn" && !root.burnConfirmOpen) {
      burnConfirm.selectedIndex = 0
      root.burnConfirmOpen = true
      return
    }
    root.burnConfirmOpen = false
    root.userCancelled = true
    waitTimer.stop()

    var pgid = root.jobPgid
    var pid = 0
    if (convertProc.running && convertProc.processId)
      pid = convertProc.processId
    else if (burnProc.running && burnProc.processId)
      pid = burnProc.processId
    if (!pgid && pid)
      pgid = pid

    if (pgid > 0)
      killerProc.exec(["/usr/bin/kill", "--", "-" + String(pgid)])

    if (convertProc.running) {
      convertProc.signal(15)
      convertProc.running = false
    }
    if (burnProc.running) {
      burnProc.signal(15)
      burnProc.running = false
    }
    if (blankProc.running) {
      blankProc.signal(15)
      blankProc.running = false
    }

    root.resetIdle(root.t("status.cancelled"))
    root.progressPct = 0
    root.notify(root.t("notify.cancelled.title"), root.t("notify.cancelled.body"))
  }

  function actionRows() {
    var rows = []
    if (root.showPackageSetup && !root.setupBusy)
      rows.push(["install"])
    if (root.showDriveSetup && !root.setupBusy)
      rows.push(["optical"])
    if (root.showWorkUi && !root.busy)
      rows.push(["pal", "ntsc"])
    if (root.showWorkUi && root.driveCount >= 2 && !root.showDiscSpin && !root.busy) {
      var drives = []
      for (var i = 0; i < root.driveCount; i++)
        drives.push("drive:" + i)
      rows.push(drives)
    }
    if (root.showWorkUi && !root.showDiscSpin && !root.busy)
      rows.push(["select"])
    var work = []
    if (root.showWorkUi && !root.showDiscSpin && (root.phase === "wait" || root.canMakeDvd))
      work.push("make")
    if (root.showWorkUi && root.busy)
      work.push("cancel")
    if (work.length)
      rows.push(work)
    if (root.showDoneUi)
      rows.push(["again"])
    return rows
  }

  function currentAction() {
    var rows = root.actionRows()
    if (!rows.length)
      return ""
    var r = Math.max(0, Math.min(root.cursorRow, rows.length - 1))
    var row = rows[r]
    var c = Math.max(0, Math.min(root.cursorCol, row.length - 1))
    return row[c]
  }

  function actionHot(id) {
    return root.cursorActive && root.currentAction() === id
  }

  function setCursorTo(id) {
    var rows = root.actionRows()
    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        if (rows[r][c] === id) {
          root.cursorActive = true
          root.cursorRow = r
          root.cursorCol = c
          root.cursorId = id
          return true
        }
      }
    }
    return false
  }

  function snapCursorToDefault() {
    var prefer = []
    if (root.showDoneUi)
      prefer.push("again")
    if (root.showDiscSpin)
      prefer.push("cancel")
    if (root.phase === "wait")
      prefer.push("make")
    if (root.canMakeDvd)
      prefer.push("make")
    if (root.showWorkUi && !root.busy)
      prefer.push("select")
    if (root.showPackageSetup)
      prefer.push("install")
    if (root.showDriveSetup)
      prefer.push("optical")
    if (root.busy)
      prefer.push("cancel")
    for (var i = 0; i < prefer.length; i++) {
      if (root.setCursorTo(prefer[i]))
        return
    }
    var rows = root.actionRows()
    if (!rows.length) {
      root.cursorId = ""
      return
    }
    root.cursorRow = 0
    root.cursorCol = 0
    root.cursorId = rows[0][0]
    root.cursorActive = true
  }

  function clampCursor() {
    if (root.setCursorTo(root.cursorId))
      return
    root.snapCursorToDefault()
  }

  function moveCursor(dx, dy) {
    root.cursorActive = true
    root.keyNav = true
    var rows = root.actionRows()
    if (!rows.length)
      return
    if (root.cursorRow >= rows.length)
      root.cursorRow = rows.length - 1
    if (dy !== 0) {
      root.cursorRow = Math.max(0, Math.min(rows.length - 1, root.cursorRow + dy))
      root.cursorCol = Math.max(0, Math.min(rows[root.cursorRow].length - 1, root.cursorCol))
    } else if (dx !== 0) {
      root.cursorCol = Math.max(0, Math.min(rows[root.cursorRow].length - 1, root.cursorCol + dx))
    }
    root.cursorId = rows[root.cursorRow][root.cursorCol]
  }

  function activateCursor() {
    root.cursorActive = true
    var id = root.currentAction()
    if (id === "install")
      root.installPackages()
    else if (id === "optical")
      root.allowDvdBurning()
    else if (id === "pal")
      root.tvStandard = "PAL"
    else if (id === "ntsc")
      root.tvStandard = "NTSC"
    else if (id.indexOf("drive:") === 0) {
      var n = parseInt(id.substring(6), 10)
      if (!isNaN(n) && n >= 0 && n < driveModel.count) {
        var path = driveModel.get(n).devPath
        if (root.isOpticalDevice(path))
          root.selectedDevice = path
      }
    } else if (id === "select")
      root.pickFile()
    else if (id === "make") {
      if (root.phase === "wait")
        root.tryBurnNow()
      else
        root.startOneShot()
    } else if (id === "cancel")
      root.cancelAll()
    else if (id === "again")
      root.makeAnother()
  }

  component SegmentedChoice: BorderSurface {
    id: seg
    property var options: []
    property string value: ""
    property real fontPx: Style.font.caption
    signal changed(string value)

    implicitHeight: Style.spacing.controlHeight
    height: visible ? implicitHeight : 0
    radius: Math.min(Style.cornerRadius, Style.space(4))
    clip: true
    color: Style.normalFillFor(root.contentForeground, Color.accent)
    borderSpec: Border.controlSpec(segHover >= 0 ? "hover-cursor" : "normal", root.contentForeground, Color.accent)

    property int segHover: -1

    function optionValue(o) {
      return (o && typeof o === "object") ? String(o.value) : String(o)
    }
    function optionLabel(o) {
      return (o && typeof o === "object") ? String(o.label) : String(o)
    }
    function optionAction(o) {
      if (o && typeof o === "object" && o.actionId)
        return String(o.actionId)
      return optionValue(o).toLowerCase()
    }

    Row {
      id: segRow
      anchors.fill: parent
      anchors.topMargin: parent.borderTop
      anchors.bottomMargin: parent.borderBottom
      anchors.leftMargin: parent.borderLeft
      anchors.rightMargin: parent.borderRight
      spacing: 0

      Repeater {
        model: seg.options

        Item {
          required property var modelData
          required property int index
          width: Math.floor(segRow.width / Math.max(seg.options.length, 1))
          height: segRow.height
          readonly property string segValue: seg.optionValue(modelData)
          readonly property string segAction: seg.optionAction(modelData)
          readonly property bool chosen: segValue === seg.value
          readonly property bool hot: mouse.containsMouse || (root.keyNav && root.actionHot(segAction))

          Rectangle {
            anchors.fill: parent
            color: chosen
              ? Style.selectedFillFor(root.contentForeground, Color.accent)
              : (hot ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent")
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(8)
            text: seg.optionLabel(modelData)
            textFormat: Text.PlainText
            elide: Text.ElideRight
            wrapMode: Text.NoWrap
            horizontalAlignment: Text.AlignHCenter
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: seg.fontPx
            font.bold: chosen
          }

          Rectangle {
            visible: index < seg.options.length - 1
            width: 1
            height: parent.height - Style.space(8)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.28)
          }

          MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: {
              seg.segHover = containsMouse ? index : (seg.segHover === index ? -1 : seg.segHover)
              if (containsMouse) {
                root.keyNav = false
                root.setCursorTo(segAction)
              }
            }
            onClicked: seg.changed(segValue)
          }
        }
      }
    }
  }

  component ActionBtn: Button {
    property string label: ""
    property string actionId: ""
    property bool on: true
    property bool chosen: false
    property real fontPx: Style.font.body
    signal activated()

    implicitHeight: Style.spacing.controlHeight
    text: label
    selected: chosen
    enabled: on
    bordered: true
    hasCursor: root.keyNav && root.actionHot(actionId)
    foreground: root.contentForeground
    fontFamily: root.contentFontFamily
    fontSize: fontPx
    radius: Math.min(Style.cornerRadius, Style.space(4))
    opacity: on ? 1.0 : 0.4
    onClicked: activated()
    onHovered: function(isHovered) {
      if (isHovered) {
        root.keyNav = false
        root.setCursorTo(actionId)
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.burnConfirmOpen) {
          burnConfirm.selectedIndex = burnConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: {
        if (root.burnConfirmOpen) {
          if (burnConfirm.selectedIndex === 0)
            root.burnConfirmOpen = false
          else
            root.cancelAll()
          return
        }
        root.activateCursor()
      }
      onCloseRequested: {
        if (root.burnConfirmOpen) {
          root.burnConfirmOpen = false
          return
        }
        root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ConfirmDialog {
        id: burnConfirm
        anchors.fill: parent
        z: 20
        opened: root.burnConfirmOpen
        selectedIndex: 0
        message: root.t("confirm.burnCancel.message")
        cancelText: root.t("confirm.burnCancel.keep")
        confirmText: root.t("confirm.burnCancel.stop")
        background: Color.popups.background
        foreground: root.contentForeground
        scrim: Util.alpha(Color.popups.background, 0.72)
        selectedBackground: Util.alpha(root.contentForeground, 0.08)
        selectedText: Color.accent
        fontFamily: root.contentFontFamily
        cornerRadius: Style.cornerRadius
        onCanceled: root.burnConfirmOpen = false
        onConfirmed: root.cancelAll()
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(12)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.t("app.header")
          color: Qt.darker(root.contentForeground, 1.5)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1
          font.bold: true
        }

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.showPackageSetup

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.t("setup.needsPackages")
            color: root.contentForeground
            wrapMode: Text.Wrap
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            visible: root.missingPkgs.length > 0
            text: root.t("setup.missing", root.plainText(root.missingPkgs.split(",").join(", ")))
            textFormat: Text.PlainText
            color: Qt.darker(root.contentForeground, 1.3)
            wrapMode: Text.Wrap
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          ActionBtn {
            width: parent.width
            label: root.t("action.installPackages")
            actionId: "install"
            on: !root.setupBusy
            onActivated: root.installPackages()
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.showDriveSetup

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.t("setup.needsDrivePermission")
            color: root.contentForeground
            wrapMode: Text.Wrap
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          ActionBtn {
            width: parent.width
            label: root.t("action.allowDvdBurning")
            actionId: "optical"
            on: !root.setupBusy
            onActivated: root.allowDvdBurning()
          }
        }

        SegmentedChoice {
          id: tvStandardRow
          width: parent.width
          visible: !root.busy && root.showWorkUi
          options: [
            { value: "PAL", label: root.t("tv.pal"), actionId: "pal" },
            { value: "NTSC", label: root.t("tv.ntsc"), actionId: "ntsc" }
          ]
          value: root.tvStandard
          onChanged: function(v) { root.tvStandard = v }
        }

        Row {
          id: driveRow
          width: parent.width
          spacing: Style.space(8)
          visible: root.showWorkUi && root.driveCount >= 2 && !root.showDiscSpin

          Repeater {
            model: driveModel
            ActionBtn {
              width: (driveRow.width - driveRow.spacing * Math.max(driveModel.count - 1, 0)) / Math.max(driveModel.count, 1)
              label: model.devLabel
              actionId: "drive:" + index
              on: !root.busy
              chosen: root.selectedDevice === model.devPath
              onActivated: {
                if (root.isOpticalDevice(model.devPath))
                  root.selectedDevice = model.devPath
              }
            }
          }
        }

        ActionBtn {
          width: parent.width
          visible: root.showWorkUi && !root.busy
          label: root.t("action.selectVideo")
          actionId: "select"
          on: !root.busy
          onActivated: root.pickFile()
        }

        Item {
          id: discStage
          width: parent.width
          height: discIcon.height + Style.space(10)
          visible: root.showDiscSpin

          Text {
            id: discIcon
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            text: "\uf51f"
            textFormat: Text.PlainText
            color: root.discColor
            font.family: "Font Awesome 7 Free Solid"
            font.pixelSize: Style.space(84)
            horizontalAlignment: Text.AlignHCenter

            Timer {
              interval: 32
              running: discStage.visible
              repeat: true
              onTriggered: discIcon.rotation = (discIcon.rotation + 1.6) % 360
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.showWorkUi && !root.showDiscSpin

          Text {
            width: parent.width
            visible: root.waitingToBurn
            text: root.t("wait.ready")
            textFormat: Text.PlainText
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            id: fileLabel
            width: parent.width
            text: root.waitingToBurn
              ? root.plainText(root.inputName)
              : (root.inputPath.length > 0 ? root.t("file.label", root.inputName) : root.t("file.none"))
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            wrapMode: Text.NoWrap
            color: root.waitingToBurn
              ? Qt.darker(root.contentForeground, 1.3)
              : root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            MouseArea {
              id: fileHover
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
            }
            PanelToolTip {
              visible: fileHover.containsMouse && root.inputPath.length > 0
              text: root.plainText(root.inputPath)
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.space(6)
          radius: Style.cornerRadius > 0 ? height / 2 : 0
          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
          visible: root.showWorkUi && root.busy && root.phase !== "wait"
          Rectangle {
            width: Math.round(parent.width * (root.progressPct / 100))
            height: parent.height
            radius: parent.radius
            color: root.showDiscSpin ? root.discColor : Style.selectedStateColor(root.contentForeground, Color.accent)
            Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
          }
        }

        Text {
          width: parent.width
          visible: root.showWorkUi
          text: root.statusText + ((root.busy && root.phase !== "wait") ? (" (" + root.progressPct + "%)") : "")
          textFormat: Text.PlainText
          color: root.contentForeground
          wrapMode: Text.WrapAnywhere
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
        }

        Column {
          width: parent.width
          spacing: Style.space(12)
          visible: root.showDoneUi

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.t("done.title")
            color: root.contentForeground
            wrapMode: Text.Wrap
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.t("done.body")
            color: Qt.darker(root.contentForeground, 1.25)
            wrapMode: Text.Wrap
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }
          ActionBtn {
            width: parent.width
            label: root.t("action.makeAnother")
            actionId: "again"
            onActivated: root.makeAnother()
          }
        }

        Row {
          width: parent.width
          spacing: root.showDiscSpin ? 0 : Style.space(8)
          visible: root.showWorkUi

          ActionBtn {
            visible: !root.showDiscSpin
            width: visible ? (parent.width - Style.space(8)) / 2 : 0
            label: root.phase === "wait" ? root.t("action.burnNow") : root.t("action.makeDvd")
            actionId: "make"
            on: root.phase === "wait" || root.canMakeDvd
            onActivated: {
              if (root.phase === "wait")
                root.tryBurnNow()
              else
                root.startOneShot()
            }
          }

          ActionBtn {
            width: root.showDiscSpin ? parent.width : (parent.width - Style.space(8)) / 2
            label: root.t("action.cancel")
            actionId: "cancel"
            on: root.busy
            onActivated: root.cancelAll()
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.showWorkUi
          text: root.t("legal")
          color: Qt.darker(root.contentForeground, 1.5)
          wrapMode: Text.Wrap
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
