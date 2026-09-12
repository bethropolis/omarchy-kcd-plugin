import QtQuick
import qs.Commons
import qs.Ui

// One Night Drive quick-action tile: icon glyph over a small label.
// Disabled tiles render dimmed and ignore clicks (v2 placeholders).
Rectangle {
  id: root

  property string iconText: ""
  property string label: ""
  property string tooltipText: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  // Accent styling for the primary action (e.g. Start pairing).
  // Opt-in; everything else renders exactly as before.
  property bool accent: false

  signal tapped()

  implicitWidth: Style.space(110)
  implicitHeight: Style.space(54)
  height: implicitHeight
  radius: Style.cornerRadius
  color: tileMouse.containsMouse && root.enabled
    ? Style.hoverFillFor(foreground, Color.accent)
    : root.accent && root.enabled
      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
      : Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)
  border.color: root.accent && root.enabled
    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.5)
    : Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)
  border.width: 1
  opacity: root.enabled ? 1.0 : 0.45

  Behavior on color { ColorAnimation { duration: 80 } }

  Column {
    anchors.centerIn: parent
    spacing: Style.space(3)

    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.iconText
      color: root.accent && root.enabled ? Color.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    id: tileMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    enabled: root.enabled
    onClicked: root.tapped()
  }

  PanelToolTip {
    visible: root.tooltipText !== "" && tileMouse.containsMouse
    text: root.tooltipText
    fontFamily: root.fontFamily
  }
}
