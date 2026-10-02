import QtQuick
import qs.Commons
import qs.Ui

// Quick-action tiles: props in, signals out. Two rows — three compact
// tiles, then two half-width so the grid stays balanced. Tiles are ordered
// by how often they get used, most-tapped first: Ring, Screenshot, Share
// up top, Files and Clipboard below. Tile enablement follows
// liveConnected. Glyph codepoints are authoritative here — FontAwesome
// range only (the panel font lacks the Material block, e.g. U+F048A
// renders blank).
Column {
  id: actions
  width: parent.width
  spacing: Style.space(12)

  property bool liveConnected: false
  property string deviceName: "phone"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property real gap: Style.space(8)

  signal tileTapped(string tile)   // "ring" | "files" | "clipboard"
  signal shareRequested()
  signal screenshotRequested()

  Text {
    textFormat: Text.PlainText
    text: "QUICK ACTIONS"
    color: actions.dim
    font.family: actions.fontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1.4
    font.bold: true
  }

  Row {
    width: parent.width
    spacing: actions.gap

    property real cellWidth: Math.max(0, (width - spacing * 2) / 3)

    QuickTile {
      width: parent.cellWidth
      iconText: ""
      label: "Ring"
      tooltipText: "Ring phone"
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      enabled: actions.liveConnected
      onTapped: actions.tileTapped("ring")
    }

    QuickTile {
      width: parent.cellWidth
      iconText: ""
      label: "Screenshot"
      tooltipText: "Send a screenshot to " + actions.deviceName
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      enabled: actions.liveConnected
      onTapped: actions.screenshotRequested()
    }

    QuickTile {
      width: parent.cellWidth
      iconText: ""
      label: "Share"
      tooltipText: "Send a file to " + actions.deviceName
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      enabled: actions.liveConnected
      onTapped: actions.shareRequested()
    }
  }

  Row {
    width: parent.width
    spacing: actions.gap

    property real cellWidth: Math.max(0, (width - spacing) / 2)

    QuickTile {
      width: parent.cellWidth
      iconText: ""
      label: "Files"
      tooltipText: "Mount the phone's storage and open it"
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      enabled: actions.liveConnected
      onTapped: actions.tileTapped("files")
    }

    QuickTile {
      width: parent.cellWidth
      iconText: ""
      label: "Clipboard"
      tooltipText: "Sync clipboard"
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      enabled: actions.liveConnected
      onTapped: actions.tileTapped("clipboard")
    }
  }
}
