import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Kcd.js" as Kcd

// Night Drive dashboard for kcd (redesigned per REVIEW.md + design.svg):
// auto-selected paired phone, battery, compact 120px media card with transport
// cluster and Canvas wave seeker, quick-action tiles, version footer.
Panel {
  id: root
  moduleName: "bet.kcd"
  ipcTarget: "bet.kcd"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- State
  property var devices: []
  property var autoDevice: Kcd.pickAutoDevice(devices)
  readonly property string deviceId: autoDevice ? String(autoDevice.id) : ""
  readonly property string deviceName: autoDevice ? String(autoDevice.name) : "No phone"
  readonly property bool deviceConnected: autoDevice ? autoDevice.connected === true : false

  property int batteryCharge: -1
  property bool batteryCharging: false
  property var track: null
  // clockMs drives displayPos re-evaluation (100ms while open+playing).
  property double clockMs: 0
  // Drift-free position from the daemon's anchor stamp: pos + elapsed
  // while playing, frozen otherwise. Without an anchor (paused/legacy)
  // we hold the last reported pos.
  readonly property double displayPos: root.anchorPos()
  property string lastSeenText: "—"
  property string daemonText: "starting…"
  property string kcdVersion: "v0.1.0"
  property bool versionOk: false
  property bool installOk: false
  property bool installProbed: false
  property bool daemonUp: false
  property bool daemonProbed: false
  property bool watchAlive: true
  property int watchBackoffMs: 2000
  property double ioStartMs: 0
  // Last successful device-list intake (any path); gates the open-path
  // devices respawn so every panel open doesn't re-poll a fresh list.
  property double devicesRxMs: 0
  // Pairing listen mode (`kcd pair -y`): true while pairProc runs.
  // Auto-accepts the first incoming request then exits on its own.
  readonly property bool pairing: pairProc.running
  // Daemon start (`systemctl --user start kcd`): true while daemonProc runs.
  readonly property bool startingDaemon: daemonProc.running

  // Display layer. Raw `track` keeps last-known data; `liveTrack` is null
  // whenever the daemon is unreachable so stale state can never render
  // as live (green dot, creeping seek, enabled buttons).
  readonly property var liveTrack: root.daemonUp ? root.track : null
  readonly property bool hasTrack: liveTrack !== null && liveTrack !== undefined
  // Single read of `liveTrack`: pairing hasTrack (separate binding,
  // possibly stale mid-transition) with .length threw on track change.
  readonly property double trackLength: {
    if (liveTrack === null || liveTrack === undefined) return 0
    var l = Number(liveTrack.length)
    return isFinite(l) && l > 0 ? l : 0
  }
  readonly property bool usableArt: hasTrack && Kcd.isUsableArt(liveTrack.albumArtUrl)
  readonly property bool playing: hasTrack && liveTrack.isPlaying === true
  readonly property bool liveConnected: root.deviceConnected && root.daemonUp
  // Missing / down / unpaired / ready. Before the first probes complete
  // this reads "ready" (status quo) so there is no boot flash.
  readonly property string uiState: {
    if (!root.installProbed || !root.daemonProbed) return "ready"
    if (!root.installOk) return "missing"
    if (!root.daemonUp) return "down"
    if (!root.autoDevice) return "unpaired"
    return "ready"
  }

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color contentDim: Qt.darker(contentForeground, 1.5)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Closed-bar mirror (read by BarWidget.qml): battery icon encodes
  // level + charging state. No playing indicator, no emoji.
  readonly property string barLabel: {
    if (batteryCharge < 0) return "󰂃 --"
    return Kcd.batteryIcon(batteryCharge, batteryCharging) + " " + batteryCharge + "%"
  }
  readonly property string barTooltip: {
    if (root.installProbed && !root.installOk) return "KDE Connect — kcd not installed"
    if (!autoDevice) return root.daemonUp && devices.length > 0 ? "KDE Connect — no paired phone" : "KDE Connect — no phone"
    var tip = deviceName + (root.liveConnected ? " — connected" : " — offline")
    if (root.daemonProbed && !root.daemonUp) tip += " (daemon not running)"
    if (hasTrack) tip += "\n" + liveTrack.title + (liveTrack.artist !== "" ? " — " + liveTrack.artist : "")
    return tip
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh(false)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh(false)
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function closeForPopoutSwitch() {
    if (root.controller && typeof root.controller.hide === "function") root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- IO: one-shot hydration (CLI) + live stream (kcd watch).
  // One-shots that fail (missing binary, dead daemon) surface through
  // their onExited handlers; nothing here blocks on success.
  function refresh(forceDevices) {
    var force = forceDevices !== false
    root.ioStartMs = Date.now()
    if (!versionProc.running && !root.versionOk) {
      versionProc.command = ["kcd", "--version"]
      versionProc.running = true
    }
    if (!devicesProc.running && (force || Date.now() - root.devicesRxMs > 120000)) {
      devicesProc.command = ["kcd", "devices", "--json"]
      devicesProc.running = true
    }
    root.fillGaps()
  }

  // One-shot fallbacks for anything the summary/snapshot didn't hydrate
  // (cold daemon caches): battery and media only, never unconditionally.
  // Stamps ioStartMs when it launches so late-cycle spawns get a full
  // wedge-guard budget.
  function fillGaps() {
    if (root.deviceId === "" || !root.daemonUp) return
    var needBattery = root.batteryCharge < 0 && !batteryProc.running
    var needMpris = !root.track && !mprisProc.running
    if (!needBattery && !needMpris) return
    root.ioStartMs = Date.now()
    if (needBattery) root.refreshBattery()
    if (needMpris) {
      mprisProc.command = ["kcd", "mpris", "status", "--json"]
      mprisProc.running = true
    }
  }

  function refreshBattery() {
    if (batteryProc.running || root.deviceId === "" || !root.daemonUp) return
    batteryProc.command = ["kcd", "battery", "--json", root.deviceId]
    batteryProc.running = true
  }

  // Pairing from a click: start `kcd pair -y` listen mode, or cancel a
  // running one. Needs the daemon (pairing goes over IPC); otherwise just
  // re-probe. Pair success arrives via the pair.accepted watch event.
  function togglePairing() {
    if (pairProc.running) {
      pairProc.running = false
      return
    }
    if (!root.installOk || !root.daemonUp) {
      root.refresh()
      return
    }
    pairProc.command = Kcd.pairCommand()
    pairProc.running = true
  }

  // One-click daemon start: `systemctl --user start kcd` is idempotent
  // (no-op if already running). onExited re-probes, so the panel leaves
  // the down state on its own once the daemon answers.
  function startDaemon() {
    if (daemonProc.running || !root.installOk) return
    daemonProc.command = ["systemctl", "--user", "start", "kcd"]
    daemonProc.running = true
  }

  Component.onCompleted: root.refresh()

  function onDevicesOutput(text) {
    root.daemonUp = true
    root.daemonProbed = true
    var devs = Kcd.parseDevicesOutput(text)
    if (devs.length === 0 && root.devices.length > 0) return
    root.applyDeviceList(devs)
  }

  // Shared device-list intake (devices one-shot + state.snapshot):
  // selection, switch reset, summary hydration, one-shot fallbacks.
  // Snapshot lists are authoritative full state (no empty-guard).
  function applyDeviceList(devs) {
    var prevId = root.deviceId
    root.devices = Kcd.stickDevice(devs, prevId)
    root.devicesRxMs = Date.now()
    var switched = root.deviceId !== prevId
    if (switched) {
      trackClearTimer.stop()
      root.batteryCharge = -1
      root.track = null
    }
    var ad = root.autoDevice
    if (ad) {
      if (ad.battery) {
        root.batteryCharge = ad.battery.charge
        root.batteryCharging = ad.battery.charging === true
      }
      if (ad.media && Kcd.isFreshMedia(ad.media)) root.setTrack(ad.media)
      // A connected phone is seen now by definition (TCP up, packets
      // flowing) — the daemon stamp only moves on (re)connect, so it
      // would age while the phone sits next to you.
      if (ad.connected) root.lastSeenText = "Now"
      else if (ad.lastSeen) root.lastSeenText = Kcd.formatLastSeen(ad.lastSeen)
      else if (switched) root.lastSeenText = "—"
    }
    root.fillGaps()
    root.daemonText = devs.length > 0 ? "kcd — " + devs.length + " phone(s)" : "kcd — no phones"
  }

  function onMprisOutput(text) {
    root.setTrack(Kcd.parseMprisStatus(text))
  }

  // Song-gap bridge: between tracks the player briefly reports empty
  // metadata (null). Clearing instantly would pulse the card 120→64→120,
  // so nulls arm a 2s grace timer instead — a valid update cancels it and
  // only a sustained absence clears the card. Intentional resets (device
  // switch) stop the timer and clear immediately.
  function setTrack(next) {
    if (next) {
      trackClearTimer.stop()
      root.track = next
    } else if (root.track !== null) {
      trackClearTimer.restart()
    }
  }

  function anchorPos() {
    var now = root.clockMs
    // liveTrack (daemon-gated), never the raw cache: a dead daemon must
    // freeze the readout instead of creeping on stale data.
    if (!root.liveTrack) return 0
    var base = Number(root.liveTrack.pos) || 0
    if (root.liveTrack.isPlaying === true && Number(root.liveTrack.posAnchorMs) > 0) {
      base += now - Number(root.liveTrack.posAnchorMs)
    }
    var len = Number(root.liveTrack.length) || 0
    if (len > 0) base = Math.min(len, base)
    return Math.max(0, base)
  }

  function onBatteryOutput(text) {
    var parsed = Kcd.parseBatteryOutput(text)
    if (!parsed) return
    root.batteryCharge = parsed.charge
    root.batteryCharging = parsed.charging
  }

  function onVersionOutput(text) {
    var v = Kcd.parseVersionOutput(text)
    if (!v) return
    root.kcdVersion = v
    root.versionOk = true
    root.installOk = true
  }

  function handleWatchLine(line) {
    var result = Kcd.parseWatchLine(line)
    if (result.skip) return
    root.watchBackoffMs = 2000
    applyEvent(result.event)
  }

  function applyEvent(event) {
    if (!event || !event.type) return
    var type = event.type
    if (type === "device.connected") {
      root.lastSeenText = "Now"
      root.refresh()
    } else if (type === "device.disconnected") {
      root.refresh()
    } else if (type === "pair.accepted" || type === "pair.requested" || type === "pair.rejected") {
      root.refresh()
    } else if (type === "state.snapshot") {
      root.daemonUp = true
      root.daemonProbed = true
      var payload = event.payload || {}
      var list = payload.devices
      root.applyDeviceList(Kcd.normalizeDevices(list instanceof Array ? list : []))
    } else if (type === "battery.update") {
      if (root.deviceId !== "" && event.deviceId !== root.deviceId) return
      var payload = event.payload || {}
      if (payload.charge !== undefined && payload.charge !== null) {
        root.batteryCharge = Math.round(Number(payload.charge))
        root.batteryCharging = payload.charging === true
      }
    } else if (type === "mpris.update") {
      if (root.deviceId !== "" && event.deviceId !== root.deviceId) return
      root.setTrack(Kcd.normalizeTrack(event.payload))
    }
  }

  function runTile(tile) {
    var cmd = Kcd.tileCommand(tile, root.deviceId)
    if (!cmd) return
    if ((tile === "ping" || tile === "ring") && root.deviceId === "") return
    Quickshell.execDetached(cmd)
  }

  function mediaAction(action) {
    Quickshell.execDetached(Kcd.mprisCommand(action, root.deviceId))
  }

  // Footer gear: edit kcd.toml in Neovim via the user's terminal
  // ($TERMINAL, falling back to xdg-terminal-exec).
  function openSettings() {
    var term = Quickshell.env("TERMINAL")
    if (!term) term = "xdg-terminal-exec"
    Quickshell.execDetached([term, "nvim", Kcd.configTomlPath(Quickshell.env("HOME"), Quickshell.env("XDG_CONFIG_HOME"))])
  }

  // Local interpolation so the wave playhead creeps while playing:
  // mpris.update only fires on real changes.
  // Deferred track clear for the song-gap bridge (see setTrack).
  Timer {
    id: trackClearTimer
    interval: 2000
    repeat: false
    onTriggered: {
      root.track = null
    }
  }

  // Repaint driver for the anchor-based position: not a clock itself,
  // just re-triggers the displayPos binding. Math stays drift-free.
  Timer {
    id: posTicker
    interval: 100
    repeat: true
    running: root.opened && root.playing
    onTriggered: {
      root.clockMs = Date.now()
    }
  }

  Timer {
    id: watchRestartTimer
    interval: root.watchBackoffMs
    repeat: false
    onTriggered: {
      root.watchAlive = true
    }
  }

  // Wedge guard: a one-shot that hasn't returned 20s after launch is
  // reaped and its probe marked done, so a dead spawn can never block
  // all future refreshes. Slow successes correct the flags on arrival.
  // Sleeps unless a probe is in flight — a wedged proc keeps it awake
  // until reaped, then it goes quiet again.
  Timer {
    id: ioTimeout
    interval: 5000
    repeat: true
    running: devicesProc.running || mprisProc.running || batteryProc.running || versionProc.running
    onTriggered: {
      if (root.ioStartMs === 0 || Date.now() - root.ioStartMs < 20000) return
      if (devicesProc.running) {
        devicesProc.running = false
        root.daemonProbed = true
        root.daemonUp = false
      }
      if (mprisProc.running) mprisProc.running = false
      if (batteryProc.running) batteryProc.running = false
      if (versionProc.running) {
        versionProc.running = false
        root.installProbed = true
        root.installOk = false
      }
    }
  }

  // Slow re-probe so installing kcd (or the daemon returning) is picked
  // up without reopening the panel. Watch events cover the rest.
  Timer {
    id: stateReprobe
    interval: 30000
    repeat: true
    running: !root.installOk || !root.daemonUp
    onTriggered: root.refresh()
  }

  // Runs only while the binary exists; the CLI itself backs off and
  // reconnects while the daemon is down. `watchAlive` (never `running`
  // directly) is flipped so the installOk gate binding stays intact.
  Process {
    id: watchProc
    running: root.installOk && root.watchAlive
    command: ["kcd", "watch", "--json", "--events", "device.connected,device.disconnected,battery.update,mpris.update,pair.accepted,pair.requested,pair.rejected"]
    stdout: SplitParser {
      onRead: function(data) { root.handleWatchLine(data) }
    }
    onExited: function(exitCode) {
      root.watchAlive = false
      if (root.installOk) {
        root.daemonText = "kcd — reconnecting…"
        root.watchBackoffMs = Math.min(root.watchBackoffMs * 2, 30000)
        watchRestartTimer.restart()
      }
    }
  }

  Process {
    id: devicesProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onDevicesOutput(text)
    }
    onExited: function(exitCode) {
      root.daemonProbed = true
      if (exitCode !== 0) {
        root.daemonUp = false
        if (root.devices.length === 0) root.daemonText = "kcd — unreachable"
      }
    }
  }

  Process {
    id: mprisProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onMprisOutput(text)
    }
  }

  Process {
    id: batteryProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onBatteryOutput(text)
    }
  }

  Process {
    id: versionProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onVersionOutput(text)
    }
    onExited: function(exitCode) {
      root.installProbed = true
      if (exitCode !== 0) root.installOk = false
    }
  }

  // Managed `kcd pair -y`: exits on its own after auto-accepting (or on
  // daemon error); survives panel close, dies with the shell. onExited
  // re-probes so a cancel/timeout returns the panel to current truth.
  Process {
    id: pairProc
    running: false
    onExited: function(exitCode) {
      root.refresh()
    }
  }

  // Managed daemon start; see startDaemon(). Short-lived by nature.
  Process {
    id: daemonProc
    running: false
    onExited: function(exitCode) {
      root.refresh()
    }
  }

  // ================= MAIN INTERFACE =================
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(dashColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: dashScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: dashColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: dashColumn
          width: dashScroll.width
          spacing: Style.space(12)

          // ---- 1. Header (ready state only)
          Item {
            width: parent.width
            visible: root.uiState === "ready"
            height: Math.max(headerLeft.height, headerRight.height)

            Row {
              id: headerLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(12)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "󰄜"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title + 6
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: root.deviceName
                  color: root.contentForeground
                  font.family: root.contentFontFamily
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
                    color: root.liveConnected ? "#4ade80" : Qt.darker(root.contentForeground, 2.0)
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.liveConnected ? "Connected" : "Offline"
                    color: root.liveConnected ? "#4ade80" : root.contentDim
                    font.family: root.contentFontFamily
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
                text: root.batteryCharge >= 0 ? Kcd.batteryIcon(root.batteryCharge, root.batteryCharging) + " " + root.batteryCharge + "%" : "󰂃 --"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                }

                Text {
                  id: wifiGlyph
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: ""
                  color: root.contentForeground
                  font.family: root.contentFontFamily
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
                    text: root.liveConnected ? (root.autoDevice && root.autoDevice.signal ? "Phone network: " + root.autoDevice.signal.label : "Phone on local network") : "Phone offline"
                    fontFamily: root.contentFontFamily
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: "Last seen: " + root.lastSeenText
                color: root.contentDim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- 2. Compact media card (120px)
          Rectangle {
            id: mediaCard
            width: parent.width
            visible: root.uiState === "ready"
            height: root.hasTrack ? Style.space(120) : Style.space(64)
            radius: Style.cornerRadius
            clip: true
            color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.07)
            border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
            border.width: 1

            Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }

            // Artwork (decode capped: phones send ~960px, the card shows
            // a ~400px crop — full decode would waste ~3.7MB per screen).
            Image {
              anchors.fill: parent
              visible: root.usableArt
              source: root.usableArt ? root.track.albumArtUrl : ""
              fillMode: Image.PreserveAspectCrop
              sourceSize.width: 480
              asynchronous: true
              cache: true
            }

            // Contrast vignette
            Rectangle {
              anchors.fill: parent
              visible: root.usableArt
              gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.65) }
                GradientStop { position: 0.4; color: Qt.rgba(0, 0, 0, 0.38) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.92) }
              }
            }

            // Fallback when no media
            Text {
              anchors.centerIn: parent
              visible: !root.hasTrack
              text: root.liveConnected ? "No media playing" : "Phone offline"
              color: root.contentDim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }

            // Active content
            Item {
              anchors.fill: parent
              anchors.margins: Style.space(12)
              visible: root.hasTrack

              // TOP ROW: track info (left) + transport controls (right)
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
                    text: root.hasTrack ? root.track.title : ""
                    color: "white"
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    visible: root.hasTrack && root.track.artist !== ""
                    text: root.hasTrack ? root.track.artist.toUpperCase() : ""
                    color: "#cbd5e1"
                    font.family: root.contentFontFamily
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
                    fontFamily: root.contentFontFamily
                    fontSize: Style.font.caption
                    enabled: root.liveConnected
                    onClicked: root.mediaAction("previous")
                  }

                  // Circular accent play/pause button
                  Rectangle {
                    width: Style.space(32)
                    height: Style.space(32)
                    radius: width / 2
                    color: "#a78bfa"
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      anchors.centerIn: parent
                      text: root.playing ? "" : ""
                      color: "#161824"
                      font.family: root.contentFontFamily
                      font.pixelSize: 13
                      font.bold: true
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      enabled: root.liveConnected
                      onClicked: root.mediaAction("toggle")
                    }
                  }

                  PanelActionButton {
                    width: Style.space(28)
                    height: Style.space(28)
                    iconText: ""
                    tooltipText: "Next"
                    foreground: "white"
                    fontFamily: root.contentFontFamily
                    fontSize: Style.font.caption
                    enabled: root.liveConnected
                    onClicked: root.mediaAction("next")
                  }
                }
              }

              // BOTTOM ROW: wavy progress seeker + unified timer badge.
              // NOTE: no verticalAlignment on Row (not a Row property);
              // children center themselves instead.
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

                  property real progressVal: Kcd.progress(root.displayPos, root.trackLength)
                  onProgressValChanged: requestPaint()
                  onWidthChanged: requestPaint()
                  onCanvasSizeChanged: requestPaint()

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
                      ctx.strokeStyle = "#a78bfa"
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

                      // 3. Playhead knob
                      var knobY = midY + Math.sin((currentX / wavelength) * 2 * Math.PI) * amplitude
                      ctx.beginPath()
                      ctx.fillStyle = "#ffffff"
                      ctx.arc(currentX, knobY, 4, 0, 2 * Math.PI)
                      ctx.fill()
                    }
                  }
                }

                // Unified timer badge (elapsed / total)
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
                    text: Kcd.positionText(root.displayPos, root.trackLength)
                    color: "#f8fafc"
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }
            }
          }

          // ---- 3. Quick actions (ready state only)
          Text {
            visible: root.uiState === "ready"
            textFormat: Text.PlainText
            text: "QUICK ACTIONS"
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.4
            font.bold: true
          }

          Grid {
            width: parent.width
            visible: root.uiState === "ready"
            columns: 3
            rowSpacing: Style.space(8)
            columnSpacing: Style.space(8)

            property real cellWidth: Math.max(0, (width - columnSpacing * 2) / 3)

            QuickTile {
              width: parent.cellWidth
              iconText: ""
              label: "Ping"
              tooltipText: "Send a ping"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              enabled: root.liveConnected
              onTapped: root.runTile("ping")
            }

            QuickTile {
              width: parent.cellWidth
              iconText: ""
              label: "Ring"
              tooltipText: "Ring phone"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              enabled: root.liveConnected
              onTapped: root.runTile("ring")
            }

            QuickTile {
              width: parent.cellWidth
              iconText: ""
              label: "Clipboard"
              tooltipText: "Sync clipboard"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              enabled: root.liveConnected
              onTapped: root.runTile("clipboard")
            }

            QuickTile {
              width: parent.cellWidth
              iconText: ""
              label: "Text"
              tooltipText: "SMS compose — v2"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              enabled: false
            }

            QuickTile {
              width: parent.cellWidth
              iconText: ""
              label: "Files"
              tooltipText: "SFTP browse — v2"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              enabled: false
            }

            QuickTile {
              width: parent.cellWidth
              iconText: ""
              label: "Share"
              tooltipText: "Share a file — v2"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              enabled: false
            }
          }

          // ---- State panels (exactly one is ever visible)
          KcdMissing {
            visible: root.uiState === "missing"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onRetryRequested: root.refresh()
          }

          KcdUnpaired {
            visible: root.uiState === "down" || root.uiState === "unpaired"
            mode: root.uiState === "down" ? "down" : "unpaired"
            pairing: root.pairing
            startingDaemon: root.startingDaemon
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onRetryRequested: root.refresh()
            onPairRequested: root.togglePairing()
            onDaemonStartRequested: root.startDaemon()
          }

          // ---- 4. Footer (live engine version, manifest fallback)
          Item {
            width: parent.width
            height: Math.max(footerLeft.height, footerRight.height)

            Row {
              id: footerLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                id: settingsGlyph
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                color: settingsMouse.containsMouse ? root.contentForeground : root.contentDim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body

                MouseArea {
                  id: settingsMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openSettings()
                }

                PanelToolTip {
                  visible: settingsMouse.containsMouse
                  text: "Open kcd.toml in Neovim"
                  fontFamily: root.contentFontFamily
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "KDE Connect"
                color: root.contentDim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                font.bold: true
              }
            }

            Text {
              id: footerRight
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "kcd " + root.kcdVersion
              color: versionMouse.containsMouse ? root.contentForeground : root.contentDim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                id: versionMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Qt.openUrlExternally("https://github.com/bethropolis/kcd")
              }

              PanelToolTip {
                visible: versionMouse.containsMouse
                text: "Open kcd on GitHub"
                fontFamily: root.contentFontFamily
              }
            }
          }
        }
      }
    }
  }
}
