import QtQuick
import qs.Commons
import qs.Ui

// Shown when kcd exists but there is no usable device. Two modes:
// "down" (daemon not answering) and "unpaired" (daemon up, nothing
// paired). One-click pairing runs `kcd pair -y` listen mode; success
// resolves automatically on pair.accepted.
Column {
  id: root

  property string mode: "down"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  // True while `kcd pair -y` listen mode runs (owned by the panel).
  property bool pairing: false
  // True while `systemctl --user start kcd` runs (owned by the panel).
  property bool startingDaemon: false

  signal retryRequested()
  signal pairRequested()
  signal daemonStartRequested()

  readonly property bool isDown: root.mode === "down"

  width: parent.width
  spacing: Style.space(10)

  Text {
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: root.isDown ? "" : ""
    color: Qt.darker(root.foreground, 1.6)
    font.family: root.fontFamily
    font.pixelSize: 40
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: root.isDown ? "Daemon not running" : "No phone paired"
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
    text: root.isDown
      ? root.startingDaemon
        ? "Starting the daemon… the panel wakes up on its own once it answers."
        : "kcd is installed but the daemon isn't answering. Tap Start daemon below — the panel wakes up on its own."
      : root.pairing
        ? "Listening for pair requests… accept the prompt on your phone and it connects on its own. Tap Pairing to cancel."
        : "No phone is paired yet. Tap Start pairing, then accept the request on your phone — it connects on its own."
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  // Primary action first, accented; second is always Retry. Down mode
  // offers one-click daemon start, unpaired mode one-click pairing.
  Row {
    width: parent.width
    spacing: Style.space(10)

    QuickTile {
      width: (parent.width - parent.spacing) / 2
      iconText: root.isDown ? "" : ""
      label: root.isDown ? (root.startingDaemon ? "Starting…" : "Start daemon") : (root.pairing ? "Pairing…" : "Start pairing")
      tooltipText: root.isDown ? "Start the kcd user service" : (root.pairing ? "Pairing mode on — tap to cancel" : "Listen for pair requests, auto-accept first")
      foreground: root.foreground
      fontFamily: root.fontFamily
      accent: true
      enabled: root.isDown ? !root.startingDaemon : true
      onTapped: root.isDown ? root.daemonStartRequested() : root.pairRequested()
    }

    QuickTile {
      width: (parent.width - parent.spacing) / 2
      iconText: ""
      label: "Retry"
      tooltipText: "Probe again"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onTapped: root.retryRequested()
    }
  }
}
