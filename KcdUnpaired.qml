import QtQuick
import qs.Commons
import qs.Ui

// No usable device: down (daemon silent), unpaired (nothing paired),
// offline (paired, unreachable). Nothing pairs without the owner.
Column {
  id: root

  property string mode: "down"
  // Paired phone in offline mode, else the pairing candidate.
  property string deviceName: "phone"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  // Status glyph and tile icons only; copy stays on `fontFamily`.
  property string iconFontFamily: fontFamily
  // True while the panel's advertisement process runs.
  property bool pairing: false
  // Pending request code for phone comparison; empty when nothing pending.
  property string verificationKey: ""
  // Decision UI keys off the id, not the code: codeless requests stay
  // refusable.
  property string pendingPairId: ""
  // Why pairing did nothing, when the kcd build is too old to advertise.
  property string pairNotice: ""
  // True while the panel's daemon-start process runs.
  property bool startingDaemon: false

  signal retryRequested()
  signal pairRequested()
  signal daemonStartRequested()
  signal acceptPairRequested()
  signal rejectPairRequested()

  readonly property bool isDown: root.mode === "down"
  readonly property bool isOffline: root.mode === "offline"
  readonly property bool hasPending: root.pendingPairId !== ""

  width: parent.width
  spacing: Style.space(10)

  Text {
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: root.isDown ? "" : (root.isOffline ? "" : "")
    color: Qt.darker(root.foreground, 1.6)
    font.family: root.iconFontFamily
    font.pixelSize: 40
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: root.isDown ? "Daemon not running" : (root.isOffline ? "Phone offline" : (root.hasPending ? "Phone wants to pair" : (root.pairing ? "Waiting for your phone" : "No phone paired")))
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
        ? root.deviceName + " is paired but not reachable. Wake the phone or open KDE Connect - the panel reconnects on its own."
        : root.hasPending
          ? "Compare the code with your phone, then accept or refuse below. Nothing pairs until you do."
          : root.pairing
            ? "Advertising for pairing... start the request on your phone. Tap Stop to cancel."
            : "No phone is paired yet. Tap Start pairing, then start the request on your phone - you will confirm the code here."
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

  // Nothing trusted yet: compare the code, then decide.
  Text {
    visible: root.hasPending
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: root.deviceName + " wants to pair"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  Text {
    visible: root.hasPending
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: root.verificationKey !== "" ? root.verificationKey : "(no code sent)"
    color: Qt.darker(root.foreground, 1.2)
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: true
  }

  // The owner decides, never the network.
  Row {
    visible: root.hasPending
    width: parent.width
    spacing: Style.space(10)

    QuickTile {
      width: (parent.width - parent.spacing) / 2
      iconText: "\uF00C"
      label: "Accept"
      tooltipText: "Pair with " + root.deviceName + " — only if the codes match"
      foreground: root.foreground
      fontFamily: root.fontFamily
      iconFontFamily: root.iconFontFamily
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
      iconFontFamily: root.iconFontFamily
      onTapped: root.rejectPairRequested()
    }
  }

  // Primary action (accented) plus Retry; while deciding, only Stop
  // remains.
  Row {
    visible: !root.hasPending
    width: parent.width
    spacing: Style.space(10)

    QuickTile {
      id: primaryTile
      visible: root.mode !== "offline"
      width: (parent.width - parent.spacing) / 2
      iconText: root.isDown ? "" : (root.pairing ? "\uF04D" : "")
      label: root.isDown ? (root.startingDaemon ? "Starting…" : "Start daemon") : (root.pairing ? "Stop" : "Start pairing")
      tooltipText: root.isDown ? "Prime the kcd socket - the daemon starts on demand" : (root.pairing ? "Stop advertising for pairing" : "Make this machine discoverable, without accepting anything")
      foreground: root.foreground
      fontFamily: root.fontFamily
      iconFontFamily: root.iconFontFamily
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
      iconFontFamily: root.iconFontFamily
      onTapped: root.retryRequested()
    }
  }

  // Full-width Stop ends the advertisement without deciding.
  Row {
    visible: root.hasPending
    width: parent.width
    spacing: Style.space(10)

    QuickTile {
      width: parent.width
      iconText: "\uF04D"
      label: "Stop pairing"
      tooltipText: "Stop advertising for pairing"
      foreground: root.foreground
      fontFamily: root.fontFamily
      iconFontFamily: root.iconFontFamily
      onTapped: root.pairRequested()
    }
  }
}
