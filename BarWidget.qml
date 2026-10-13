import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Kcd.js" as Kcd

// Closed-bar readout mirroring panel state (weather BarWidget pattern).
// The panel owns all kcd state.
BarWidget {
  id: root
  moduleName: "io.github.bethropolis.kcd"

  readonly property string panelLabel: panelLoader.item ? String(panelLoader.item.barLabel || "") : ""
  readonly property string panelTooltip: panelLoader.item ? String(panelLoader.item.barTooltip || "") : ""
  readonly property bool panelConnected: panelLoader.item ? panelLoader.item.liveConnected === true : false
  // Probed icon family; empty until the panel loads, hence the theme
  // fallback.
  readonly property string panelIconFont: panelLoader.item ? String(panelLoader.item.contentIconFont || "") : ""
  // Figures keep the theme family; the icon-plus-figures label overlays
  // two Texts (one Text, one family).
  readonly property string barFontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property string barIconFont: root.panelIconFont !== "" ? root.panelIconFont : root.barFontFamily
  readonly property string labelText: root.panelLabel !== "" ? root.panelLabel : "󰄜 --"
  readonly property string labelIcon: Kcd.barLabelRuns(root.labelText).icon
  readonly property string labelFigures: Kcd.barLabelRuns(root.labelText).figures

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

  // Bar.findPanelWidget needs open/close/opened on this root.
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

  // Routing reaches the panel above; no IpcHandler here so the target
  // registers exactly once.

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Full string stays set for sizing; the built-in label hides for the
    // two runs.
    text: root.labelText
    labelVisible: false
    fontFamily: root.barFontFamily
    dimmed: !root.panelConnected
    tooltipText: root.panelTooltip !== "" ? root.panelTooltip : "kcd Phone"
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    // Icon and figures in their own families, mirroring WidgetButton's
    // label treatment to line up.
    Row {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: !button.centerFigures || button.vertical
        ? 0
        : (figMetrics.descent - figMetrics.ascent + figMetrics.tightBoundingRect("0").height) / 2
      spacing: 0

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: root.labelIcon
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: root.barIconFont
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: root.labelFigures
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: root.barFontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }
    }

    FontMetrics {
      id: figMetrics
      font.family: root.barFontFamily
      font.pixelSize: button.fontSize
    }
  }
}
