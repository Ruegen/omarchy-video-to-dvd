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
  readonly property var barIdentity: hostWidget || root

  property string tvStandard: "PAL"
  property string scriptPath: Qt.resolvedUrl("video-to-dvd.sh").toString().replace("file://", "")
  property string inputPath: ""
  property string inputName: "No file selected"
  property string outputIso: ""
  property int progressPct: 0
  property string statusText: "Idle"
  property bool busy: false
  property bool converted: false
  property bool userCancelled: false
  property bool waitNotified: false
  property int jobPgid: 0
  property string phase: "idle"

  property bool setupProbed: false
  property bool setupBusy: false
  property string missingPkgs: ""
  property bool packagesReady: false
  property string driveStatus: "none"
  property string selectedDevice: ""

  readonly property int driveCount: driveModel.count
  readonly property bool showPackageSetup: root.setupProbed && !root.packagesReady
  readonly property bool showDriveSetup: root.setupProbed && root.driveStatus === "need-permission"
  readonly property bool canMakeDvd: !root.busy && root.packagesReady && root.inputPath.length > 0

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
        driveModel.append({ "devPath": path, "devLabel": label })
    }
  }

  function finalizeDrives() {
    var found = false
    var i
    for (i = 0; i < driveModel.count; i++) {
      if (driveModel.get(i).devPath === root.selectedDevice) {
        found = true
        break
      }
    }
    if (!found)
      root.selectedDevice = driveModel.count > 0 ? driveModel.get(0).devPath : ""
  }

  function applySetupStatus() {
    if (root.busy) return
    if (!root.packagesReady) {
      root.statusText = "Install packages to continue"
      return
    }
    if (root.driveStatus === "none") {
      if (!root.inputPath)
        root.statusText = "No DVD drive found"
      return
    }
    if (root.driveStatus === "need-permission") {
      if (!root.inputPath)
        root.statusText = "Idle"
      return
    }
    if (root.statusText === "Install packages to continue"
        || root.statusText === "No DVD drive found")
      root.statusText = root.inputPath ? "Ready" : "Idle"
  }

  function probeSetup() {
    if (root.setupBusy) return
    if (checkSetupProc.running) return
    driveModel.clear()
    checkSetupProc.running = true
  }

  function installPackages() {
    if (root.setupBusy || root.packagesReady || root.busy) return
    root.setupBusy = true
    root.statusText = "Installing packages…"
    setupProc.command = ["bash", root.scriptPath, "install-packages"]
    setupProc.running = true
  }

  function allowDvdBurning() {
    if (root.setupBusy || root.driveStatus !== "need-permission" || root.busy) return
    root.setupBusy = true
    root.statusText = "Allowing DVD burning…"
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
        root.statusText = root.driveCount === 0 ? "No DVD drive found" : "Ready"
      }
    }
    onExited: function(code) {
      // Exit 1 = nothing picked (not an error).
      if (code > 1 && !root.busy)
        root.statusText = "Could not open the file picker"
    }
  }
  function pickFile() {
    if (root.busy) return
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
    onExited: function() {
      root.setupBusy = false
      root.probeSetup()
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
          var parts = line.split(":")
          var pct = parseInt(parts[1])
          if (!isNaN(pct)) root.progressPct = pct
          root.statusText = parts.slice(2).join(":")
        } else if (line.indexOf("RESULT:OK:") === 0) {
          root.statusText = "Converted"
          root.converted = true
          if (!root.userCancelled) {
            if (root.driveCount === 0)
              root.resetIdle("No DVD drive found")
            else
              root.enterWaitForDisc()
          }
        } else if (line.indexOf("RESULT:ERROR:") === 0) {
          root.handleJobError(line.substring(13), "DVD convert failed")
        }
      }
    }
    onExited: function(code) {
      root.onJobExited(code, "convert", "DVD convert failed", "Convert failed (exit " + code + ")")
    }
  }

  Timer {
    id: waitTimer
    interval: 2000
    repeat: true
    onTriggered: {
      if (root.phase !== "wait" || root.userCancelled) {
        waitTimer.stop()
        return
      }
      if (!blankProc.running)
        blankProc.running = true
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
        var t = line.trim()
        if (root.phase !== "wait" || root.userCancelled) return
        if (t === "BLANK:YES") {
          waitTimer.stop()
          root.phase = "burn"
          root.statusText = "Burning"
          burnProc.running = true
        } else if (t === "BLANK:TOO_SMALL") {
          root.statusText = "Disc is too small for this ISO — insert a higher capacity DVD"
          if (!root.waitNotified) {
            root.waitNotified = true
            root.notify("Disc too small", "The inserted disc lacks sufficient capacity for the video ISO.")
          }
        } else if (t === "BLANK:NO") {
          root.statusText = "Disc is not blank — insert a blank DVD"
          if (!root.waitNotified) {
            root.waitNotified = true
            root.notify("Insert a blank DVD", "Disc is not blank — insert a blank DVD.")
          }
        } else {
          root.statusText = "Insert a blank DVD"
          if (!root.waitNotified) {
            root.waitNotified = true
            root.notify("Waiting for a blank DVD", "Insert a blank DVD to continue.")
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
          root.statusText = line.substring(14)
        } else if (line.indexOf("RESULT:BURNED:") === 0) {
          root.converted = true
          root.resetIdle("DVD burned")
          root.notify("DVD burned", "The disc is ready.")
        } else if (line.indexOf("RESULT:ERROR:") === 0) {
          root.handleJobError(line.substring(13), "DVD burn failed")
        }
      }
    }
    onExited: function(code) {
      root.onJobExited(code, "burn", "DVD burn failed", "Burn failed (exit " + code + ")")
    }
  }

  function handleJobError(err, failTitle) {
    if (root.userCancelled || err === "cancelled") {
      if (err === "cancelled" && !root.userCancelled) {
        root.userCancelled = true
        root.notify("DVD cancelled", "The DVD job was cancelled.")
      }
      waitTimer.stop()
      root.resetIdle("Cancelled")
      return
    }
    waitTimer.stop()
    root.resetIdle("Error: " + err)
    root.notify(failTitle, root.statusText)
  }

  function onJobExited(code, expectedPhase, failTitle, fallbackStatus) {
    if (root.userCancelled) {
      waitTimer.stop()
      root.resetIdle("Cancelled")
      return
    }
    if (code === 0) return
    if (root.phase !== expectedPhase) return
    waitTimer.stop()
    if (root.statusText.indexOf("Error:") !== 0)
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
    root.statusText = "Insert a blank DVD"
    if (!blankProc.running)
      blankProc.running = true
    waitTimer.start()
  }

  function startOneShot() {
    if (root.busy) return
    if (!root.packagesReady) { root.statusText = "Install packages first"; return }
    if (!root.inputPath) { root.statusText = "Select a file first"; return }
    root.userCancelled = false
    root.waitNotified = false
    root.jobPgid = 0
    root.busy = true
    root.converted = false
    root.progressPct = 0
    root.phase = "convert"
    root.statusText = "Starting"
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

    root.resetIdle("Cancelled")
    root.progressPct = 0
    root.notify("DVD cancelled", "The DVD job was cancelled.")
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
          text: "VIDEO TO DVD"
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
            text: "Needs a few Arch packages to convert and burn."
            color: root.contentForeground
            wrapMode: Text.Wrap
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            visible: root.missingPkgs.length > 0
            text: "Missing: " + root.missingPkgs.split(",").join(", ")
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
              text: "Install packages"
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
            text: "This account cannot use the DVD drive yet."
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
              text: "Allow DVD burning"
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
          visible: !root.busy

          Repeater {
            model: [ { label: "PAL (576i 25fps)", std: "PAL" }, { label: "NTSC (480i 29.97fps)", std: "NTSC" } ]
            Rectangle {
              width: (tvStandardRow.width - tvStandardRow.spacing) / 2
              height: Style.space(32)
              radius: Style.cornerRadius
              color: root.tvStandard === modelData.std
                ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.18)
                : (tvMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08))
              Text {
                anchors.centerIn: parent
                text: modelData.label
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
          visible: root.driveCount >= 2

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
          opacity: root.busy ? 0.4 : 1.0
          color: selectMouse.containsMouse && !root.busy
            ? Style.hoverFillFor(root.contentForeground, Color.accent)
            : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
          Text {
            anchors.centerIn: parent
            text: "Select video"
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
          text: "File: " + root.inputName
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

          Rectangle {
            width: (parent.width - Style.space(8)) / 2
            height: Style.space(32)
            radius: Style.cornerRadius
            opacity: root.canMakeDvd ? 1.0 : 0.4
            color: makeMouse.containsMouse && root.canMakeDvd
              ? Style.hoverFillFor(root.contentForeground, Color.accent)
              : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
            Text {
              anchors.centerIn: parent
              text: "Make DVD"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }
            MouseArea {
              id: makeMouse
              anchors.fill: parent
              hoverEnabled: true
              enabled: root.canMakeDvd
              cursorShape: Qt.PointingHandCursor
              onClicked: root.startOneShot()
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
              text: "Cancel"
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
          text: "Only convert and burn content you have the right to copy."
          color: Qt.darker(root.contentForeground, 1.5)
          wrapMode: Text.Wrap
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
