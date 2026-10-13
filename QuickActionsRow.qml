import QtQuick
import qs.Commons
import qs.Ui

// Two tile rows (three compact, then two half-width), most-tapped
// first. Glyphs are FontAwesome-range only (no Material block).
Column {
  id: actions
  width: parent.width
  spacing: Style.space(12)

  property bool liveConnected: false
  // Mounted storage turns the Files tile into Unmount, so the mount
  // never lingers unnoticed.
  property bool storageMounted: false
  property string deviceName: "phone"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  // Icons use the probed covering family; labels use `fontFamily`.
  property string iconFontFamily: fontFamily
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
      iconFontFamily: actions.iconFontFamily
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
      iconFontFamily: actions.iconFontFamily
      enabled: actions.liveConnected
      onTapped: actions.screenshotRequested()
    }

    QuickTile {
      width: parent.cellWidth
      iconText: ""
      label: "Clipboard"
      tooltipText: "Sync clipboard"
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      iconFontFamily: actions.iconFontFamily
      enabled: actions.liveConnected
      onTapped: actions.tileTapped("clipboard")
    }
  }

  Row {
    width: parent.width
    spacing: actions.gap

    property real cellWidth: Math.max(0, (width - spacing) / 2)

    QuickTile {
      width: parent.cellWidth
      iconText: ""
      label: "Share"
      tooltipText: "Send a file to " + actions.deviceName
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      iconFontFamily: actions.iconFontFamily
      enabled: actions.liveConnected
      onTapped: actions.shareRequested()
    }

    QuickTile {
      width: parent.cellWidth
      iconText: actions.storageMounted ? "" : ""
      label: actions.storageMounted ? "Unmount" : "Files"
      tooltipText: actions.storageMounted
        ? "Unmount the phone's storage"
        : "Mount the phone's storage and open it"
      foreground: actions.foreground
      fontFamily: actions.fontFamily
      iconFontFamily: actions.iconFontFamily
      enabled: actions.liveConnected
      onTapped: actions.tileTapped("files")
    }
  }
}
