import QtQuick
import qs.Commons
import qs.Ui

// No kcd IO attempted here; explainer plus manual re-probe.
Column {
  id: root

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  // Status glyph and Retry icon only; text stays on `fontFamily`.
  property string iconFontFamily: fontFamily

  signal retryRequested()

  width: parent.width
  spacing: Style.space(10)

  Text {
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: ""
    color: Qt.darker(root.foreground, 1.6)
    font.family: root.iconFontFamily
    font.pixelSize: 40
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: "kcd not installed"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
    font.bold: true
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    text: "This panel needs the kcd daemon. Install it, then tap Retry."
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  QuickTile {
    width: parent.width
    iconText: ""
    label: "Retry"
    tooltipText: "Check again for kcd"
    foreground: root.foreground
    fontFamily: root.fontFamily
    iconFontFamily: root.iconFontFamily
    enabled: true
    onTapped: root.retryRequested()
  }
}
