import QtQuick
import qs.Commons
import qs.Ui
import "Kcd.js" as Kcd

// Device header (Step 2 of the Panel split): phone name, connection dot,
// battery readout, wifi glyph + tooltip, last-seen line. Pure read-only
// inputs — no signals; the wifi hover state is self-contained.
// Glyph codepoints are authoritative here — see Panel.qml history,
// not REVIEW.md (whose snippets had them stripped).
Item {
  id: header
  width: parent.width
  height: Math.max(headerLeft.height, headerRight.height)

  property string deviceName: "No phone"
  property bool liveConnected: false
  property int batteryCharge: -1
  property bool batteryCharging: false
  // Precomputed by the caller — avoids passing the whole device object.
  property string networkTooltip: "Phone offline"
  property string lastSeenText: "—"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.5)

  Row {
    id: headerLeft
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(12)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "󰄜"
      color: header.foreground
      font.family: header.fontFamily
      font.pixelSize: Style.font.title + 6
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: header.deviceName
        color: header.foreground
        font.family: header.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
        width: Math.min(implicitWidth, Style.space(160))
      }

      Row {
        spacing: Style.space(6)

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(7)
          height: Style.space(7)
          radius: width / 2
          color: header.liveConnected ? "#4ade80" : Qt.darker(header.foreground, 2.0)
        }

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: header.liveConnected ? "Connected" : "Offline"
          color: header.liveConnected ? "#4ade80" : header.dim
          font.family: header.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }
  }

  Column {
    id: headerRight
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Row {
      anchors.right: parent.right
      spacing: Style.space(10)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: header.batteryCharge >= 0
          ? Kcd.batteryIcon(header.batteryCharge, header.batteryCharging) + " " + header.batteryCharge + "%"
          : "󰂃 --"
        color: header.foreground
        font.family: header.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        id: wifiGlyph
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: ""
        color: header.foreground
        font.family: header.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true

        MouseArea {
          id: wifiMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.ArrowCursor
        }

        PanelToolTip {
          visible: wifiMouse.containsMouse
          text: header.networkTooltip
          fontFamily: header.fontFamily
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.right: parent.right
      text: "Last seen: " + header.lastSeenText
      color: header.dim
      font.family: header.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
