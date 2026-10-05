import QtQuick
import qs.Commons
import qs.Ui

// Shown when kcd exists but there is no usable device. Three modes:
// "down" (daemon not answering), "unpaired" (daemon up, nothing paired)
// and "offline" (paired phone unreachable, e.g. asleep). One-click
// pairing runs `kcd pair -y` listen mode; success resolves automatically
// on pair.accepted. Offline needs no action — reconnect resolves itself.
Column {
  id: root

  property string mode: "down"
  // Phone name: the paired device in offline mode, or the candidate
  // asking to pair.
  property string deviceName: "phone"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  // True while `kcd pair --advertise-only` runs (owned by the panel).
  property bool pairing: false
  // Code from the pending pair request, so the phone's code can be
  // compared before anything is trusted. Empty when nothing is pending.
  property string verificationKey: ""
  // Why pairing did nothing, when the kcd build is too old to advertise.
  property string pairNotice: ""
  // True while `systemctl --user start kcd` runs (owned by the panel).
  property bool startingDaemon: false

  signal retryRequested()
  signal pairRequested()
  signal daemonStartRequested()
  signal acceptPairRequested()
  signal rejectPairRequested()

  readonly property bool isDown: root.mode === "down"
  readonly property bool isOffline: root.mode === "offline"

  width: parent.width
  spacing: Style.space(10)

  Text {
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: root.isDown ? "" : (root.isOffline ? "" : "")
    color: Qt.darker(root.foreground, 1.6)
    font.family: root.fontFamily
    font.pixelSize: 40
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: root.isDown ? "Daemon not running" : (root.isOffline ? "Phone offline" : "No phone paired")
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
      : root.isOffline
        ? root.deviceName + " is paired but not reachable. Wake the phone or open KDE Connect — the panel reconnects on its own."
        : root.pairing
          ? (root.verificationKey !== ""
            ? "Compare the code with your phone, then accept or refuse below. Nothing pairs until you do."
            : "Advertising for pairing… start the request on your phone. Tap Pairing to stop.")
          : "No phone is paired yet. Tap Start pairing, then start the request on your phone — you will confirm the code here."
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Text {
    visible: root.pairNotice !== ""
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    text: root.pairNotice
    color: Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  // A phone is asking to pair. Nothing is trusted yet: show the code so
  // the owner can compare it against the phone, and require a decision.
  Text {
    visible: root.verificationKey !== ""
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: root.verificationKey === "" ? "" : root.deviceName + " wants to pair"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  Text {
    visible: root.verificationKey !== ""
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: root.verificationKey
    color: Qt.darker(root.foreground, 1.2)
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: true
  }

  // Accept or refuse the candidate. This replaces Start pairing while a
  // request is on screen: the owner decides, never the network.
  Row {
    visible: root.verificationKey !== ""
    width: parent.width
    spacing: Style.space(10)

    QuickTile {
      width: (parent.width - parent.spacing) / 2
      iconText: "\uF00C"
      label: "Accept"
      tooltipText: "Pair with " + root.deviceName + " — only if the codes match"
      foreground: root.foreground
      fontFamily: root.fontFamily
      accent: true
      onTapped: root.acceptPairRequested()
    }

    QuickTile {
      width: (parent.width - parent.spacing) / 2
      iconText: "\uF00D"
      label: "Refuse"
      tooltipText: "Send a rejection to " + root.deviceName
      foreground: root.foreground
      fontFamily: root.fontFamily
      onTapped: root.rejectPairRequested()
    }
  }

  // Primary action first, accented; second is always Retry. Down mode
  // offers one-click daemon start, unpaired mode one-click pairing.
  Row {
    width: parent.width
    spacing: Style.space(10)

    QuickTile {
      id: primaryTile
      visible: root.mode !== "offline"
      width: (parent.width - parent.spacing) / 2
      iconText: root.isDown ? "" : ""
      label: root.isDown ? (root.startingDaemon ? "Starting…" : "Start daemon") : (root.pairing ? "Pairing…" : "Start pairing")
      tooltipText: root.isDown ? "Prime the kcd socket — the daemon starts on demand" : (root.pairing ? "Pairing mode on — tap to cancel" : "Listen for pair requests, auto-accept first")
      foreground: root.foreground
      fontFamily: root.fontFamily
      accent: true
      enabled: root.isDown ? !root.startingDaemon : true
      onTapped: root.isDown ? root.daemonStartRequested() : root.pairRequested()
    }

    QuickTile {
      width: primaryTile.visible ? (parent.width - parent.spacing) / 2 : parent.width
      iconText: ""
      label: "Retry"
      tooltipText: "Probe again"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onTapped: root.retryRequested()
    }
  }
}
