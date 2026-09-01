import QtQuick
import Quickshell
import qs.Ui

// Video → DVD bar widget: a simple button that opens the conversion panel.
// Icon is Font Awesome's solid "compact-disc" glyph (U+F51F), matching the
// same icon-via-glyph pattern used by SystemUpdate.qml and Tray.qml in the
// built-in shell — it inherits the bar's foreground color automatically.
BarWidget {
  id: root
  moduleName: "io.github.ruegen.video-to-dvd"

  I18n { id: i18n }

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false

  function open() {
    root.injectPanel()
    if (panelLoader.item) panelLoader.item.open()
  }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() {
    root.injectPanel()
    if (panelLoader.item) panelLoader.item.toggle()
  }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    if ("settings" in panelLoader.item)
      panelLoader.item.settings = root.settings
  }

  onSettingsChanged: injectPanel()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fontFamily: "Font Awesome 7 Free Solid"
    text: "\uf51f"
    tooltipText: i18n.t("bar.tooltip")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}
