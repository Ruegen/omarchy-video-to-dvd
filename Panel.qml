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
  property string scriptPath: Qt.resolvedUrl("video-to-dvd.sh").toString().replace("file://", "")
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

  onPackagesReadyChanged: root.applySetupStatus()

  readonly property int driveCount: driveModel.count
  readonly property bool showPackageSetup: root.setupProbed && !root.packagesReady
  readonly property bool showDriveSetup: root.setupProbed && root.packagesReady && root.driveStatus === "need-permission"
  readonly property bool showMainActions: root.packagesReady && !root.showDriveSetup
  readonly property bool canMakeDvd: !root.busy && root.showMainActions && root.inputPath.length > 0

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

  function deriveOutputIso(path) {
    return path.replace(/\.[^./]+$/, "") + ".iso"
  }

  function notify(title, body) {
    notifyProc.exec(["bash", root.scriptPath, "notify", title, body || ""])
  }

  function resetIdle(status) {
    root.busy = false
    root.phase = "idle"
    root.jobPgid = 0
    if (status !== undefined)
      root.statusText = status
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
      if (path.length > 0)
        driveModel.append({ "devPath": path, "devLabel": root.translateDriveLabel(label) })
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
    if (root.settings && root.settings.selectedDevice)
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
  onSelectedDeviceChanged: root.persistChoices()

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
    if (found)
      root.selectedDevice = preferred
    else
      root.selectedDevice = driveModel.count > 0 ? driveModel.get(0).devPath : ""
  }

  function clearSetupBusy() {
    root.setupBusy = false
    root.setupKind = ""
    setupPollTimer.stop()
  }

  function applySetupStatus() {
    if (root.busy) return

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

  function probeSetup(force) {
    if (root.setupBusy && !force) return
    if (checkSetupProc.running) {
      if (force) return
      checkSetupProc.running = false
    }
    driveModel.clear()
    checkSetupProc.command = ["bash", root.scriptPath, "check-setup"]
    checkSetupProc.running = true
  }

  function installPackages() {
    if (root.setupBusy || root.packagesReady || root.busy) return
    root.setupKind = "packages"
    root.setupBusy = true
    root.statusText = root.t("status.installingPackages")
    setupPollTimer.start()
    setupProc.command = ["bash", root.scriptPath, "install-packages"]
    setupProc.running = true
  }

  function allowDvdBurning() {
    if (root.setupBusy || root.driveStatus !== "need-permission" || root.busy) return
    root.setupKind = "drive"
    root.setupBusy = true
    root.statusText = root.t("status.allowingBurning")
    setupPollTimer.start()
    setupProc.command = ["bash", root.scriptPath, "add-optical"]
    setupProc.running = true
  }

  onOpenedChanged: {
    if (root.opened)
      root.probeSetup()
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
        var p = root.stripFileUri(line.trim())
        if (p.length === 0) return
        root.inputPath = p
        root.inputName = p.split("/").pop()
        root.outputIso = root.deriveOutputIso(p)
        root.converted = false
        root.progressPct = 0
        root.statusText = root.driveCount === 0 ? root.t("status.noDrive") : root.t("status.ready")
      }
    }
    onExited: function(code) {
      // Exit 1 = nothing picked (not an error).
      if (code > 1 && !root.busy)
        root.statusText = root.t("status.pickerFailed")
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
    command: ["bash", root.scriptPath, "check-setup"]
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
    command: ["bash", root.scriptPath, "install-packages"]
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
    command: ["bash", root.scriptPath, "convert", root.inputPath, root.outputIso]
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
    if (root.phase !== "wait" || root.userCancelled)
      return
    if (blankProc.running)
      blankProc.running = false
    Qt.callLater(function() {
      if (root.phase === "wait" && !root.userCancelled)
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
    interval: 1500
    repeat: true
    onTriggered: {
      if (root.phase !== "wait" || root.userCancelled) {
        waitTimer.stop()
        return
      }
      root.pollBlank()
    }
  }

  Process {
    id: blankProc
    command: root.outputIso.length > 0 && root.selectedDevice.length > 0
      ? ["bash", root.scriptPath, "check-blank", root.selectedDevice, root.outputIso]
      : (root.selectedDevice.length > 0
          ? ["bash", root.scriptPath, "check-blank", root.selectedDevice]
          : ["bash", root.scriptPath, "check-blank"])
    stdout: SplitParser {
      onRead: function(line) {
        var tline = line.trim()
        if (root.phase !== "wait" || root.userCancelled) return
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
      ? ["bash", root.scriptPath, "burn", root.outputIso, root.selectedDevice]
      : ["bash", root.scriptPath, "burn", root.outputIso]
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
          root.converted = true
          root.resetIdle(root.t("status.dvdBurned"))
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

    if (pgid)
      killerProc.exec(["bash", "-c", "kill -- -" + pgid + " 2>/dev/null || kill " + pgid + " 2>/dev/null || true"])

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
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(12)

        Text {
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
            text: root.t("setup.missing", root.missingPkgs.split(",").join(", "))
            color: Qt.darker(root.contentForeground, 1.3)
            wrapMode: Text.Wrap
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            width: parent.width
            height: Style.space(32)
            radius: Style.cornerRadius
            opacity: root.setupBusy ? 0.4 : 1.0
            color: installMouse.containsMouse && !root.setupBusy
              ? Style.hoverFillFor(root.contentForeground, Color.accent)
              : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
            Text {
              anchors.centerIn: parent
              text: root.t("action.installPackages")
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }
            MouseArea {
              id: installMouse
              anchors.fill: parent
              hoverEnabled: true
              enabled: !root.setupBusy
              cursorShape: Qt.PointingHandCursor
              onClicked: root.installPackages()
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.showDriveSetup

          Text {
            width: parent.width
            text: root.t("setup.needsDrivePermission")
            color: root.contentForeground
            wrapMode: Text.Wrap
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          Rectangle {
            width: parent.width
            height: Style.space(32)
            radius: Style.cornerRadius
            opacity: root.setupBusy ? 0.4 : 1.0
            color: driveMouse.containsMouse && !root.setupBusy
              ? Style.hoverFillFor(root.contentForeground, Color.accent)
              : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
            Text {
              anchors.centerIn: parent
              text: root.t("action.allowDvdBurning")
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }
            MouseArea {
              id: driveMouse
              anchors.fill: parent
              hoverEnabled: true
              enabled: !root.setupBusy
              cursorShape: Qt.PointingHandCursor
              onClicked: root.allowDvdBurning()
            }
          }
        }

        Row {
          id: tvStandardRow
          width: parent.width
          spacing: Style.space(8)
          visible: !root.busy && root.showMainActions

          Repeater {
            model: [
              { labelKey: "tv.pal", std: "PAL" },
              { labelKey: "tv.ntsc", std: "NTSC" }
            ]
            Rectangle {
              width: (tvStandardRow.width - tvStandardRow.spacing) / 2
              height: Style.space(32)
              radius: Style.cornerRadius
              color: root.tvStandard === modelData.std
                ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.18)
                : (tvMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08))
              Text {
                anchors.centerIn: parent
                text: root.t(modelData.labelKey)
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                id: tvMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.tvStandard = modelData.std
              }
            }
          }
        }

        Row {
          id: driveRow
          width: parent.width
          spacing: Style.space(8)
          visible: root.showMainActions && root.driveCount >= 2

          Repeater {
            model: driveModel
            Rectangle {
              width: (driveRow.width - driveRow.spacing * Math.max(driveModel.count - 1, 0)) / Math.max(driveModel.count, 1)
              height: Style.space(32)
              radius: Style.cornerRadius
              opacity: root.busy ? 0.4 : 1.0
              color: {
                var selected = root.selectedDevice === model.devPath
                if (selected)
                  return Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.18)
                if (drivePickMouse.containsMouse && !root.busy)
                  return Style.hoverFillFor(root.contentForeground, Color.accent)
                return Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
              }
              Text {
                anchors.centerIn: parent
                width: parent.width - Style.space(8)
                text: model.devLabel
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                horizontalAlignment: Text.AlignHCenter
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea {
                id: drivePickMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.busy
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectedDevice = model.devPath
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.space(32)
          radius: Style.cornerRadius
          visible: root.showMainActions
          opacity: root.busy ? 0.4 : 1.0
          color: selectMouse.containsMouse && !root.busy
            ? Style.hoverFillFor(root.contentForeground, Color.accent)
            : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
          Text {
            anchors.centerIn: parent
            text: root.t("action.selectVideo")
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }
          MouseArea {
            id: selectMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: !root.busy
            cursorShape: Qt.PointingHandCursor
            onClicked: root.pickFile()
          }
        }

        Text {
          id: fileLabel
          width: parent.width
          visible: root.showMainActions
          text: root.inputPath.length > 0 ? root.t("file.label", root.inputName) : root.t("file.none")
          elide: Text.ElideMiddle
          wrapMode: Text.NoWrap
          color: root.contentForeground
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
            text: root.inputPath
          }
        }

        Rectangle {
          width: parent.width
          height: Style.space(6)
          radius: Style.cornerRadius > 0 ? height / 2 : 0
          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
          visible: root.busy || root.converted
          Rectangle {
            width: Math.round(parent.width * (root.progressPct / 100))
            height: parent.height
            radius: parent.radius
            color: Style.selectedStateColor(root.contentForeground, Color.accent)
            Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
          }
        }

        Text {
          width: parent.width
          text: root.statusText + ((root.busy && root.phase !== "wait") ? (" (" + root.progressPct + "%)") : "")
          color: root.contentForeground
          wrapMode: Text.WrapAnywhere
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
        }

        Row {
          width: parent.width
          spacing: Style.space(8)
          visible: root.showMainActions

          Rectangle {
            width: (parent.width - Style.space(8)) / 2
            height: Style.space(32)
            radius: Style.cornerRadius
            opacity: (root.phase === "wait" || root.canMakeDvd) ? 1.0 : 0.4
            color: makeMouse.containsMouse && (root.phase === "wait" || root.canMakeDvd)
              ? Style.hoverFillFor(root.contentForeground, Color.accent)
              : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
            Text {
              anchors.centerIn: parent
              text: root.phase === "wait" ? root.t("action.burnNow") : root.t("action.makeDvd")
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }
            MouseArea {
              id: makeMouse
              anchors.fill: parent
              hoverEnabled: true
              enabled: root.phase === "wait" || root.canMakeDvd
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.phase === "wait")
                  root.tryBurnNow()
                else
                  root.startOneShot()
              }
            }
          }

          Rectangle {
            width: (parent.width - Style.space(8)) / 2
            height: Style.space(32)
            radius: Style.cornerRadius
            opacity: root.busy ? 1.0 : 0.4
            color: cancelMouse.containsMouse && root.busy
              ? Style.hoverFillFor(root.contentForeground, Color.accent)
              : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
            Text {
              anchors.centerIn: parent
              text: root.t("action.cancel")
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }
            MouseArea {
              id: cancelMouse
              anchors.fill: parent
              hoverEnabled: true
              enabled: root.busy
              cursorShape: Qt.PointingHandCursor
              onClicked: root.cancelAll()
            }
          }
        }

        Text {
          width: parent.width
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
