import QtQuick
import Quickshell
import Quickshell.Io
import "Kcd.js" as Kcd

// kcd IO engine (Step 4 of the Panel split): every Process/Timer, all raw
// kcd state, and every function that only touches them. Non-visual.
// Panel.qml owns panel-open/UI state and calls in through the functions
// below; it reads state through the properties below. Private-by-convention:
// handlers (on*Output/apply*/handle*/setTrack/anchorPos) are io-internal.
QtObject {
  id: io

  // Input from Panel.qml (posTicker needs it; everything else is push).
  property bool panelOpen: false

  // Installed location of this plugin (scripts live beside the QML).
  // Single source so the spawn halves below can't drift apart.
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.bethropolis.kcd"

  // ---- State
  property var devices: []
  readonly property var autoDevice: Kcd.pickAutoDevice(devices)
  // First paired device regardless of connection: distinguishes "paired
  // but offline" (phone asleep, TCP down) from "never paired".
  readonly property var pairedDevice: Kcd.pickPairedDevice(devices)
  readonly property string pairedName: pairedDevice ? String(pairedDevice.name) : "phone"
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
  readonly property double displayPos: io.anchorPos()
  property string lastSeenText: "—"
  property string daemonText: "starting…"
  // "—" until the version probe lands: never a fake version. In the
  // missing state the footer reads "kcd —".
  property string kcdVersion: "—"
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
  readonly property var liveTrack: io.daemonUp ? io.track : null
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
  readonly property bool liveConnected: io.deviceConnected && io.daemonUp
  // Missing / down / unpaired / offline / ready. Before the first
  // probes complete this reads "ready" (status quo) so there is no boot
  // flash. Offline = paired but unreachable (phone asleep): patience,
  // not another pair request.
  readonly property string uiState: {
    if (!io.installProbed || !io.daemonProbed) return "ready"
    if (!io.installOk) return "missing"
    if (!io.daemonUp) return "down"
    if (!io.autoDevice) return io.pairedDevice ? "offline" : "unpaired"
    return "ready"
  }

  // ---- Closed-bar mirror (read by BarWidget.qml): battery icon encodes
  // level + charging state. No playing indicator, no emoji.
  readonly property string barLabel: {
    if (batteryCharge < 0) return "󰂃 --"
    return Kcd.batteryIcon(batteryCharge, batteryCharging) + " " + batteryCharge + "%"
  }
  readonly property string barTooltip: {
    if (io.installProbed && !io.installOk) return "kcd Phone — kcd not installed"
    if (!autoDevice) {
      if (io.pairedDevice) return io.pairedName + " — offline (asleep?)"
      return io.daemonUp && devices.length > 0 ? "kcd Phone — no paired phone" : "kcd Phone — no phone"
    }
    var tip = deviceName + (io.liveConnected ? " — connected" : " — offline")
    if (io.daemonProbed && !io.daemonUp) tip += " (daemon not running)"
    if (hasTrack) tip += "\n" + liveTrack.title + (liveTrack.artist !== "" ? " — " + liveTrack.artist : "")
    return tip
  }

  // ---- IO: one-shot hydration (CLI) + live stream (kcd watch).
  // One-shots that fail (missing binary, dead daemon) surface through
  // their onExited handlers; nothing here blocks on success.
  function refresh(forceDevices) {
    var force = forceDevices !== false
    io.ioStartMs = Date.now()
    // Version probe re-runs on every refresh (not just until first
    // success): a latched installOk would blind reopen to a removed
    // binary. While the probe runs the flags hold, so there is no flash;
    // on exit they carry current truth. One local sh spawn per open.
    if (!versionProc.running) {
      // Wrapped in sh so the spawn always reports an exit: a missing kcd
      // binary fails the spawn itself (no onExited), which used to wedge
      // the probes and strand the panel in zombie "ready". sh exits 127
      // instead, completing the probe as "missing".
      versionProc.command = ["sh", "-c", "kcd --version"]
      versionProc.running = true
    }
    if (!devicesProc.running && (force || Date.now() - io.devicesRxMs > 120000)) {
      devicesProc.command = ["sh", "-c", "kcd devices --json"]
      devicesProc.running = true
    }
    io.fillGaps()
  }

  // One-shot fallbacks for anything the intake didn't hydrate:
  // devices one-shots embed no battery/media (the top-up in
  // applyDeviceList covers those); this covers the remaining paths.
  // Stamps ioStartMs when it launches so late-cycle spawns get a full
  // wedge-guard budget.
  function fillGaps() {
    if (io.deviceId === "" || !io.daemonUp) return
    var needBattery = io.batteryCharge < 0 && !batteryProc.running
    var needMpris = !io.track && !mprisProc.running
    if (!needBattery && !needMpris) return
    io.ioStartMs = Date.now()
    if (needBattery) io.refreshBattery()
    if (needMpris) {
      mprisProc.command = ["sh", "-c", "kcd mpris status --json"]
      mprisProc.running = true
    }
  }

  function refreshBattery() {
    if (batteryProc.running || io.deviceId === "" || !io.daemonUp) return
    batteryProc.command = ["sh", "-c", "kcd battery --json '" + io.deviceId + "'"]
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
    if (!io.installOk || !io.daemonUp) {
      io.refresh()
      return
    }
    pairProc.command = Kcd.pairCommand()
    pairProc.running = true
  }

  // One-click daemon start: `systemctl --user start kcd` is idempotent
  // (no-op if already running). onExited re-probes, so the panel leaves
  // the down state on its own once the daemon answers.
  function startDaemon() {
    if (daemonProc.running || !io.installOk) return
    daemonProc.command = ["systemctl", "--user", "start", "kcd"]
    daemonProc.running = true
  }

  function onDevicesOutput(text) {
    io.daemonUp = true
    io.daemonProbed = true
    var devs = Kcd.parseDevicesOutput(text)
    if (devs.length === 0 && io.devices.length > 0) return
    io.applyDeviceList(devs)
  }

  // Shared device-list intake (devices one-shot + state.snapshot):
  // selection, switch reset, summary hydration, one-shot fallbacks.
  // Snapshot lists are authoritative full state (no empty-guard).
  function applyDeviceList(devs) {
    var prevId = io.deviceId
    io.devices = Kcd.stickDevice(devs, prevId)
    io.devicesRxMs = Date.now()
    var switched = io.deviceId !== prevId
    if (switched) {
      trackClearTimer.stop()
      io.batteryCharge = -1
      io.track = null
    }
    var ad = io.autoDevice
    if (ad) {
      if (ad.battery) {
        io.batteryCharge = ad.battery.charge
        io.batteryCharging = ad.battery.charging === true
      }
      if (ad.media && Kcd.isFreshMedia(ad.media)) io.setTrack(ad.media)
      // Devices one-shots embed no battery/media (unlike snapshots): top
      // them up so a stale or poisoned value heals on intake instead of
      // waiting for a change event that never comes at steady state.
      // User/open-driven, overlap-guarded; snapshot intakes skip (embedded).
      if (!ad.battery && !batteryProc.running) io.refreshBattery()
      if (!ad.media && !mprisProc.running) {
        mprisProc.command = ["sh", "-c", "kcd mpris status --json"]
        mprisProc.running = true
      }
      // A connected phone is seen now by definition (TCP up, packets
      // flowing) — the daemon stamp only moves on (re)connect, so it
      // would age while the phone sits next to you.
      if (ad.connected) io.lastSeenText = "Now"
      else if (ad.lastSeen) io.lastSeenText = Kcd.formatLastSeen(ad.lastSeen)
      else if (switched) io.lastSeenText = "—"
    }
    io.fillGaps()
    io.daemonText = devs.length > 0 ? "kcd — " + devs.length + " phone(s)" : "kcd — no phones"
  }

  function onMprisOutput(text) {
    io.setTrack(Kcd.parseMprisStatus(text))
  }

  // Song-gap bridge: between tracks the player briefly reports empty
  // metadata (null). Clearing instantly would pulse the card 120→64→120,
  // so nulls arm a 2s grace timer instead — a valid update cancels it and
  // only a sustained absence clears the card. Intentional resets (device
  // switch) stop the timer and clear immediately.
  function setTrack(next) {
    if (next) {
      trackClearTimer.stop()
      io.track = next
    } else if (io.track !== null) {
      trackClearTimer.restart()
    }
  }

  function anchorPos() {
    var now = io.clockMs
    // liveTrack (daemon-gated), never the raw cache: a dead daemon must
    // freeze the readout instead of creeping on stale data.
    if (!io.liveTrack) return 0
    var base = Number(io.liveTrack.pos) || 0
    if (io.liveTrack.isPlaying === true && Number(io.liveTrack.posAnchorMs) > 0) {
      base += now - Number(io.liveTrack.posAnchorMs)
    }
    var len = Number(io.liveTrack.length) || 0
    if (len > 0) base = Math.min(len, base)
    return Math.max(0, base)
  }

  function onBatteryOutput(text) {
    var parsed = Kcd.parseBatteryOutput(text)
    if (!parsed) return
    io.batteryCharge = parsed.charge
    io.batteryCharging = parsed.charging
  }

  function onVersionOutput(text) {
    var v = Kcd.parseVersionOutput(text)
    if (!v) return
    io.kcdVersion = v
    io.versionOk = true
    io.installOk = true
  }

  function handleWatchLine(line) {
    var result = Kcd.parseWatchLine(line)
    if (result.skip) return
    io.watchBackoffMs = 2000
    applyEvent(result.event)
  }

  function applyEvent(event) {
    if (!event || !event.type) return
    var type = event.type
    if (type === "device.connected") {
      io.lastSeenText = "Now"
      io.refresh()
    } else if (type === "device.disconnected") {
      io.refresh()
    } else if (type === "pair.accepted" || type === "pair.requested" || type === "pair.rejected") {
      io.refresh()
    } else if (type === "state.snapshot") {
      io.daemonUp = true
      io.daemonProbed = true
      var payload = event.payload || {}
      var list = payload.devices
      io.applyDeviceList(Kcd.normalizeDevices(list instanceof Array ? list : []))
    } else if (type === "battery.update") {
      if (io.deviceId !== "" && event.deviceId !== io.deviceId) return
      var payload = event.payload || {}
      if (payload.charge !== undefined && payload.charge !== null) {
        io.batteryCharge = Math.round(Number(payload.charge))
        io.batteryCharging = payload.charging === true
      }
    } else if (type === "mpris.update") {
      if (io.deviceId !== "" && event.deviceId !== io.deviceId) return
      io.setTrack(Kcd.normalizeTrack(event.payload))
    }
  }

  function runTile(tile) {
    var cmd = Kcd.tileCommand(tile, io.deviceId)
    if (!cmd) return
    if ((tile === "ping" || tile === "ring") && io.deviceId === "") return
    Quickshell.execDetached(cmd)
  }

  // shareFile() here is only the process-spawn half: Panel.qml owns the
  // deviceId guard and closes the panel first (the portal chooser takes
  // over from there). Invoked through bash so a lost exec bit on deploy
  // can never break it.
  function shareFile(deviceId, deviceName) {
    Quickshell.execDetached(["bash", io.pluginDir + "/kcd-share.sh", deviceId, deviceName])
  }

  // screenshotShare() mirrors shareFile(): Panel.qml owns the deviceId
  // guard and closes the panel first (grim must not catch it); the
  // script waits out the hide animation itself before capturing.
  function screenshotShare(deviceId, deviceName) {
    Quickshell.execDetached(["bash", io.pluginDir + "/kcd-screenshot-share.sh", deviceId, deviceName])
  }



  function mediaAction(action) {
    Quickshell.execDetached(Kcd.mprisCommand(action, io.deviceId))
  }

  // Local interpolation so the wave playhead creeps while playing:
  // mpris.update only fires on real changes.
  // Deferred track clear for the song-gap bridge (see setTrack).
  property Timer trackClearTimer: Timer {
    interval: 2000
    repeat: false
    onTriggered: {
      io.track = null
    }
  }

  // Repaint driver for the anchor-based position: not a clock itself,
  // just re-triggers the displayPos binding. Math stays drift-free.
  property Timer posTicker: Timer {
    interval: 100
    repeat: true
    running: io.panelOpen && io.playing
    onTriggered: {
      io.clockMs = Date.now()
    }
  }

  property Timer watchRestartTimer: Timer {
    interval: io.watchBackoffMs
    repeat: false
    onTriggered: {
      io.watchAlive = true
    }
  }

  // Spawn watchdog: a watch (re)start that yields no line within 10s is a
  // silent spawn failure (missing binary reports no exit, wedging
  // running=true with no process and no retry). Force it through the
  // normal exit path so backoff engages. Disarmed by the first line, so
  // steady state adds zero timers; every (re)start begins with a daemon
  // dump, so a quiet-but-live stream still disarms immediately.
  property Timer watchStreamGuard: Timer {
    interval: 10000
    repeat: false
    onTriggered: {
      io.watchProc.running = false
      io.noteWatchFailure()
    }
  }

  // First watch line: stream is real — disarm the guard.
  function noteWatchLine() {
    io.watchStreamGuard.stop()
  }

  // Shared watch-death path (real exits via onExited, silent failures via
  // the guard above): mark down immediately, back off, retry while the
  // binary is installed. Per-open version probes keep installOk truthful,
  // so a missing binary quiets the loop on the next open.
  function noteWatchFailure() {
    io.watchAlive = false
    io.daemonUp = false
    if (!io.installOk) return
    io.daemonText = "kcd — reconnecting…"
    io.watchBackoffMs = Math.min(io.watchBackoffMs * 2, 30000)
    io.watchRestartTimer.restart()
  }

  // Wedge guard: a one-shot that hasn't returned 20s after launch is
  // reaped and its probe marked done, so a dead spawn can never block
  // all future refreshes. Slow successes correct the flags on arrival.
  // Sleeps unless a probe is in flight — a wedged proc keeps it awake
  // until reaped, then it goes quiet again.
  property Timer ioTimeout: Timer {
    interval: 5000
    repeat: true
    running: io.devicesProc.running || io.mprisProc.running || io.batteryProc.running || io.versionProc.running
    onTriggered: {
      if (io.ioStartMs === 0 || Date.now() - io.ioStartMs < 20000) return
      if (io.devicesProc.running) {
        io.devicesProc.running = false
        io.daemonProbed = true
        io.daemonUp = false
      }
      if (io.mprisProc.running) io.mprisProc.running = false
      if (io.batteryProc.running) io.batteryProc.running = false
      if (io.versionProc.running) {
        io.versionProc.running = false
        io.installProbed = true
        io.installOk = false
      }
    }
  }

  // Panel-open and retry-tap refreshes, intake top-ups, and the watch
  // lifecycle (plus its spawn guard) are the only re-probe paths:
  // installing kcd is picked up on the next open or retry, and the
  // daemon's return arrives as a watch snapshot. No background timer —
  // an unhealthy plugin spawns nothing while the panel is closed.

  // Runs only while the binary exists; the CLI itself backs off and
  // reconnects while the daemon is down. `watchAlive` (never `running`
  // directly) is flipped so the installOk gate binding stays intact.
  property Process watchProc: Process {
    running: io.installOk && io.watchAlive
    command: ["kcd", "watch", "--json", "--events", "device.connected,device.disconnected,battery.update,mpris.update,pair.accepted,pair.requested,pair.rejected"]
    stdout: SplitParser {
      onRead: function(data) { io.noteWatchLine(); io.handleWatchLine(data) }
    }
    onRunningChanged: {
      if (running) io.watchStreamGuard.restart()
    }
    onExited: function(exitCode) {
      io.noteWatchFailure()
    }
  }

  property Process devicesProc: Process {
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: io.onDevicesOutput(text)
    }
    onExited: function(exitCode) {
      io.daemonProbed = true
      if (exitCode !== 0) {
        io.daemonUp = false
        if (io.devices.length === 0) io.daemonText = "kcd — unreachable"
      }
    }
  }

  property Process mprisProc: Process {
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: io.onMprisOutput(text)
    }
  }

  property Process batteryProc: Process {
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: io.onBatteryOutput(text)
    }
  }

  property Process versionProc: Process {
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: io.onVersionOutput(text)
    }
    onExited: function(exitCode) {
      io.installProbed = true
      if (exitCode !== 0) {
        io.installOk = false
        io.versionOk = false
      }
    }
  }

  // Managed `kcd pair -y`: exits on its own after auto-accepting (or on
  // daemon error); survives panel close, dies with the shell. onExited
  // re-probes so a cancel/timeout returns the panel to current truth.
  property Process pairProc: Process {
    running: false
    onExited: function(exitCode) {
      io.refresh()
    }
  }

  // Managed daemon start; see startDaemon(). Short-lived by nature.
  property Process daemonProc: Process {
    running: false
    onExited: function(exitCode) {
      io.refresh()
    }
  }
}
