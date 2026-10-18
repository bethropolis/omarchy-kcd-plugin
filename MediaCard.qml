import QtQuick
import qs.Commons
import qs.Ui
import "Kcd.js" as Kcd

// Compact media card: album art, transport cluster, Canvas wave seeker +
// timer badge. Props in, one signal out; `visible` lives on the call site.
Rectangle {
  id: card
  width: parent.width

  property bool hasTrack: false
  property var track: null          // { title, artist, albumArtUrl, ... }
  property bool usableArt: false
  property bool playing: false
  property bool liveConnected: false
  // False when the player reports seeking meaningless (streams).
  property bool canSeek: true
  property double displayPos: 0
  property double trackLength: 0
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  // Icon glyphs only; title, artist and timer keep `fontFamily`.
  property string iconFontFamily: fontFamily
  readonly property color dim: Qt.darker(foreground, 1.5)
  // Theme accent (Color.accent) drives the seeker and play button,
  // never a hardcoded color.
  property color accent: Color.accent
  readonly property string onAccent: accent.hslLightness > 0.5 ? "#161824" : "#ffffff"

  signal mediaAction(string action)  // "previous" | "toggle" | "next"
  signal volumeAdjust(int delta)  // percent-point step from the wheel
  signal mediaSeek(double posMs)  // absolute target ms from a wave drag
  // Volume readout ms, -1 when idle. The badge swaps to "vol N%" while
  // shown so volume needs no chrome and shifts no layout.
  property int volPreview: -1
  function showVolume(v) {
    card.volPreview = v
    volTimer.restart()
  }
  property Timer volTimer: Timer {
    interval: 2000
    repeat: false
    onTriggered: {
      card.volPreview = -1
    }
  }
  // Drag preview ms, -1 when idle; wave and badge render it while held.
  property double seekPreviewMs: -1
  function seekTo(ms) {
    if (!card.liveConnected || !card.canSeek || !(card.trackLength > 0)) return
    card.seekPreviewMs = Math.max(0, Math.min(card.trackLength, ms))
  }
  function finishSeek() {
    if (card.seekPreviewMs < 0) return
    var target = card.seekPreviewMs
    card.seekPreviewMs = -1
    card.mediaSeek(target)
  }

  // Changed-handlers don't fire for values already set at creation.
  Component.onCompleted: syncArtSource()

  // Canvas wants a CSS string; a QML color doesn't stringify reliably,
  // so build it from components.
  function accentCss() {
    function h(v) { var s = Math.round(v * 255).toString(16); return s.length === 1 ? "0" + s : s }
    return "#" + h(card.accent.r) + h(card.accent.g) + h(card.accent.b)
  }

  // Event-driven art: artPending while fetching, file:// URL on arrival.
  // Transient failures retry a few times, then stop.
  property int artAttempt: 0
  readonly property bool artPending: card.track !== null && card.track !== undefined && card.track.artPending === true
  readonly property bool artLoading: card.hasTrack && (card.artPending || artwork.status === Image.Loading) && artwork.status !== Image.Ready
  function artUrl() {
    return (card.usableArt && card.track) ? String(card.track.albumArtUrl || "") : ""
  }
  function syncArtSource() {
    artwork.source = artUrl()
  }
  onTrackChanged: {
    artAttempt = 0
    artRetry.stop()
    syncArtSource()
  }
  onUsableArtChanged: {
    artAttempt = 0
    artRetry.stop()
    syncArtSource()
  }
  property Timer artRetry: Timer {
    interval: 2500
    repeat: false
    onTriggered: {
      if (card.artAttempt >= 8 || !card.usableArt) return
      card.artAttempt++
      // Clear-then-restore: reassigning the identical URL would not refire.
      artwork.source = ""
      Qt.callLater(function() { artwork.source = card.artUrl() })
    }
  }

  height: card.hasTrack ? Style.space(120) : Style.space(64)
  radius: Style.cornerRadius
  clip: true
  color: Qt.rgba(card.foreground.r, card.foreground.g, card.foreground.b, 0.07)
  border.color: Qt.rgba(card.foreground.r, card.foreground.g, card.foreground.b, 0.08)
  border.width: 1

  Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }

  // Decode capped (480px crop of ~960px phone art). Driven imperatively:
  // a binding would break on the first retry poke.
  Image {
    id: artwork
    anchors.fill: parent
    visible: status === Image.Ready
    fillMode: Image.PreserveAspectCrop
    sourceSize.width: 480
    asynchronous: true
    cache: true
    onStatusChanged: {
      if (status === Image.Error && card.usableArt && card.artAttempt < 8) card.artRetry.restart()
      else if (status !== Image.Loading) card.artRetry.stop()
    }
  }

  // Shimmer while fetching or loading, distinct from failed/idle.
  Text {
    id: artPlaceholder
    anchors.centerIn: parent
    visible: card.artLoading
    textFormat: Text.PlainText
    text: ""
    color: card.dim
    font.family: card.iconFontFamily
    font.pixelSize: Style.font.title + 10

    SequentialAnimation on opacity {
      running: artPlaceholder.visible
      loops: Animation.Infinite
      NumberAnimation { to: 0.3; duration: 750; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 0.8; duration: 750; easing.type: Easing.InOutQuad }
    }
  }

  Rectangle {
    anchors.fill: parent
    visible: artwork.status === Image.Ready
    gradient: Gradient {
      GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.65) }
      GradientStop { position: 0.4; color: Qt.rgba(0, 0, 0, 0.38) }
      GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.92) }
    }
  }

  Text {
    anchors.centerIn: parent
    visible: !card.hasTrack
    text: card.liveConnected ? "No media playing" : "Phone offline"
    color: card.dim
    font.family: card.fontFamily
    font.pixelSize: Style.font.body
  }

  Item {
    anchors.fill: parent
    anchors.margins: Style.space(12)
    visible: card.hasTrack

    Item {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: Style.space(40)

      Column {
        anchors.left: parent.left
        anchors.right: controlsCluster.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: card.hasTrack && card.track ? card.track.title : ""
          color: "white"
          font.family: card.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: card.hasTrack && !!card.track && card.track.artist !== ""
          text: card.hasTrack && card.track ? card.track.artist.toUpperCase() : ""
          color: "#cbd5e1"
          font.family: card.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.1
          elide: Text.ElideRight
        }
      }

      Row {
        id: controlsCluster
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        PanelActionButton {
          width: Style.space(28)
          height: Style.space(28)
          iconText: ""
          tooltipText: "Previous"
          foreground: "white"
          fontFamily: card.iconFontFamily
          fontSize: Style.font.caption
          enabled: card.liveConnected
          onClicked: card.mediaAction("previous")
        }

        Rectangle {
          width: Style.space(32)
          height: Style.space(32)
          radius: width / 2
          color: card.accent
          anchors.verticalCenter: parent.verticalCenter

          Text {
            anchors.centerIn: parent
            text: card.playing ? "" : ""
            color: card.onAccent
            font.family: card.iconFontFamily
            font.pixelSize: 13
            font.bold: true
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            enabled: card.liveConnected
            onClicked: card.mediaAction("toggle")
          }
        }

        PanelActionButton {
          width: Style.space(28)
          height: Style.space(28)
          iconText: ""
          tooltipText: "Next"
          foreground: "white"
          fontFamily: card.iconFontFamily
          fontSize: Style.font.caption
          enabled: card.liveConnected
          onClicked: card.mediaAction("next")
        }
      }
    }

    // Bottom row: wave seeker + timer badge. Row has no
    // verticalAlignment; children center themselves.
    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      spacing: Style.space(8)

      Canvas {
        id: waveCanvas
        height: Style.space(18)
        width: parent.width - timerBadge.width - Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        // Paint in device pixels so the wave stays crisp.
        canvasSize: Qt.size(Math.max(1, Math.round(width)), Math.max(1, Math.round(height)))

        property real progressVal: Kcd.progress(card.seekPreviewMs >= 0 ? card.seekPreviewMs : card.displayPos, card.trackLength)
        // Local mirror so a theme-accent change repaints even when paused.
        property color accent: card.accent
        onProgressValChanged: requestPaint()
        onWidthChanged: requestPaint()
        onCanvasSizeChanged: requestPaint()
        onAccentChanged: requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)

          var totalW = width
          var midY = height / 2
          var currentX = Math.max(0, Math.min(totalW, totalW * progressVal))

          // 1. Unplayed straight tail
          ctx.beginPath()
          ctx.strokeStyle = "rgba(255, 255, 255, 0.22)"
          ctx.lineWidth = 2.5
          ctx.lineCap = "round"
          ctx.moveTo(currentX, midY)
          ctx.lineTo(totalW, midY)
          ctx.stroke()

          // 2. Played sine wave
          if (currentX > 0) {
            ctx.beginPath()
            ctx.strokeStyle = card.accentCss()
            ctx.lineWidth = 2.5
            ctx.lineCap = "round"

            var wavelength = 24
            var amplitude = 3.5

            ctx.moveTo(0, midY)
            for (var x = 0; x <= currentX; x += 2) {
              var y = midY + Math.sin((x / wavelength) * 2 * Math.PI) * amplitude
              ctx.lineTo(x, y)
            }
            ctx.stroke()

            // 3. Playhead knob (contrasting tone, readable on the wave)
            var knobY = midY + Math.sin((currentX / wavelength) * 2 * Math.PI) * amplitude
            ctx.beginPath()
            ctx.fillStyle = card.onAccent
            ctx.arc(currentX, knobY, 4, 0, 2 * Math.PI)
            ctx.fill()
          }
        }

        // Press/drag previews, release commits. Dead without connection
        // and length, so streams can't seek at 0.
        MouseArea {
          anchors.fill: parent
          enabled: card.liveConnected && card.canSeek && card.trackLength > 0
          cursorShape: card.liveConnected && card.canSeek && card.trackLength > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
          preventStealing: true
          onPressed: function(mouse) { card.seekTo(mouse.x / width * card.trackLength) }
          onPositionChanged: function(mouse) { if (pressed) card.seekTo(mouse.x / width * card.trackLength) }
          onReleased: function() { card.finishSeek() }
          onCanceled: function() { card.seekPreviewMs = -1 }
        }
      }

      Rectangle {
        id: timerBadge
        width: Style.space(82)
        height: Style.space(20)
        radius: height / 2
        anchors.verticalCenter: parent.verticalCenter
        color: Qt.rgba(0, 0, 0, 0.5)
        border.color: Qt.rgba(255, 255, 255, 0.12)
        border.width: 1

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: card.volPreview >= 0 ? "vol " + card.volPreview + "%" : Kcd.positionText(card.seekPreviewMs >= 0 ? card.seekPreviewMs : card.displayPos, card.trackLength)
          color: "#f8fafc"
          font.family: card.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }
  }

  // Wheel anywhere on the card steps volume; NoButton keeps clicks for the
  // transport and wave. Unknown or boundary levels spawn nothing.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    enabled: card.liveConnected && card.hasTrack
    onWheel: function(wheel) {
      var steps = Math.round(wheel.angleDelta.y / 120)
      if (steps === 0 || !card.track) return
      var v = Kcd.stepVolume(card.track.volume, steps * 5)
      if (v === null) return
      card.showVolume(v)
      card.volumeAdjust(steps * 5)
    }
  }
}
