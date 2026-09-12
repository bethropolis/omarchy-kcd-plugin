import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button for the Night Drive kcd panel: phone glyph + battery +
// playback dot. The panel owns all kcd state; this widget only mirrors
// it for the closed-bar read-out, following the weather BarWidget pattern.
BarWidget {
  id: root
  moduleName: "bet.kcd"

  readonly property string panelLabel: panelLoader.item ? String(panelLoader.item.barLabel || "") : ""
  readonly property string panelTooltip: panelLoader.item ? String(panelLoader.item.barTooltip || "") : ""
  readonly property bool panelConnected: panelLoader.item ? panelLoader.item.liveConnected === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  // Summon/hide/toggle routing reaches the panel through the functions
  // above (Bar.findPanelWidget); no IpcHandler here so target bet.kcd is
  // registered exactly once (Panel base owns it, weather pattern).

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.panelLabel !== "" ? root.panelLabel : "󰄜 --"
    dimmed: !root.panelConnected
    tooltipText: root.panelTooltip !== "" ? root.panelTooltip : "KDE Connect"
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
