import QtQuick
import qs.Commons
import qs.Ui

// Quick-action tile grid (Step 1 of the Panel split): props in, signals
// out. Tile enablement follows liveConnected; Text/Files stay dimmed v2
// placeholders. Glyph codepoints are authoritative here — see Panel.qml
// history, not REVIEW.md (whose snippets had them stripped).
Column {
  id: actions
  width: parent.width
  spacing: Style.space(12)

  property bool liveConnected: false
  property string deviceName: "phone"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.5)

  signal tileTapped(string tile)   // "ping" | "ring" | "clipboard"
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

  Grid {
    width: parent.width
    columns: 3
    rowSpacing: Style.space(8)
    columnSpacing: Style.space(8)

    property real cellWidth: Math.max(0, (width - columnSpacing * 2) / 3)

    QuickTile {
      width: parent.cellWidth
      iconText: ""
      label: "Ping"
      tooltipText: "Send a ping"
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      enabled: actions.liveConnected
      onTapped: actions.tileTapped("ping")
    }

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
      iconText: ""
      label: "Clipboard"
      tooltipText: "Sync clipboard"
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      enabled: actions.liveConnected
      onTapped: actions.tileTapped("clipboard")
    }

    QuickTile {
      width: parent.cellWidth
      iconText: ""
      label: "Text"
      tooltipText: "SMS compose — v2"
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      enabled: false
    }

    QuickTile {
      width: parent.cellWidth
      iconText: ""
      label: "Files"
      tooltipText: "SFTP browse — v2"
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      enabled: false
    }

    QuickTile {
      width: parent.cellWidth
      iconText: ""
      label: "Share"
      tooltipText: "Send a file to " + actions.deviceName
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      enabled: actions.liveConnected
      onTapped: actions.shareRequested()
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
  }
}
