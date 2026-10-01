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
  // Verification key from the last pair.requested, shown while pairing.
  property string verificationKey: ""
  property bool installOk: false
  property bool installProbed: false
  property bool daemonUp: false
  property bool daemonProbed: false
  property bool watchAlive: true
  // Set by reconnectWatch() so the death path it triggers restarts at
  // once instead of backing off; cleared on use.
  property bool watchRestartRequested: false
  property int watchBackoffMs: 2000
  property double ioStartMs: 0
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

  // ---- Refresh: the only CLI call left is the version probe.
  // All panel state arrives over the watch stream (state.snapshot on
  // connect, then battery/mpris/connectivity/device/pair events), so a
  // refresh re-checks the binary and bounces the stream for a fresh
  // snapshot instead of re-reading state through the CLI.
  function refresh() {
    // Re-runs on every refresh (not latched): a stale installOk would
    // blind reopen to a removed binary. While the probe runs the flags
    // hold, so there is no flash; on exit they carry current truth.
    if (!versionProc.running) {
      // Wrapped in sh so the spawn always reports an exit: a missing kcd
      // binary fails the spawn itself (no onExited). sh exits 127
      // instead, completing the probe as "missing".
      versionProc.command = ["sh", "-c", "kcd --version"]
      versionProc.running = true
    }
    io.reconnectWatch()
  }

  // Refresh as a stream bounce: every watch connect starts with a fresh
  // state.snapshot, so this is a real re-read with no CLI round-trip.
  // Drops the stream and lets the death path restart it immediately, so
  // the intentional exit neither backs off nor blinks the panel "down".
  function reconnectWatch() {
    if (!io.installOk || !io.watchAlive) return
    io.watchRestartTimer.stop()
    io.watchBackoffMs = 2000
    io.watchRestartRequested = true
    io.watchAlive = false
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

  // One-click daemon start: primes `kcd.socket` (kcd >= 1.18 ships the
  // socket unit; the service unit stays installed for activation).
  // systemctl is idempotent (no-op if already up). The next probe/watch
  // connect then summons the daemon on demand; onExited re-probes, so
  // the panel leaves the down state on its own once it answers.
  function startDaemon() {
    if (daemonProc.running || !io.installOk) return
    daemonProc.command = ["systemctl", "--user", "start", "kcd.socket"]
    daemonProc.running = true
  }

  // Device-list intake from state.snapshot: the daemon's authoritative
  // full state (devices with embedded battery/media/signal), so there is
  // no partial list to top up and no empty-guard.
  function applyDeviceList(devs) {
    var prevId = io.deviceId
    io.devices = Kcd.stickDevice(devs, prevId)
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
      // A connected phone is seen now by definition (TCP up, packets
      // flowing) — the daemon stamp only moves on (re)connect, so it
      // would age while the phone sits next to you.
      if (ad.connected) io.lastSeenText = "Now"
      else if (ad.lastSeen) io.lastSeenText = Kcd.formatLastSeen(ad.lastSeen)
      else if (switched) io.lastSeenText = "—"
    }
    io.daemonText = devs.length > 0 ? "kcd — " + devs.length + " phone(s)" : "kcd — no phones"
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
      io.handleDeviceConnected(event.deviceId, event.timestamp, event.payload)
    } else if (type === "device.disconnected") {
      io.handleDeviceDisconnected(event.deviceId, event.timestamp)
    } else if (type === "device.added") {
      io.handleDeviceAdded(event.deviceId, event.payload)
    } else if (type === "device.removed") {
      io.handleDeviceRemoved(event.deviceId)
    } else if (type === "pair.requested") {
      io.verificationKey = String((event.payload || {}).verificationKey || "")
    } else if (type === "pair.accepted") {
      io.verificationKey = ""
      io.applyPairState(event.deviceId, "PAIRED")
    } else if (type === "pair.rejected") {
      io.verificationKey = ""
      io.applyPairState(event.deviceId, "UNPAIRED")
    } else if (type === "connectivity.update") {
      io.applySignal(event.deviceId, event.payload)
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

  // First-seen device: the daemon reports strangers as UNPAIRED and
  // disconnected (no auto-dial), so a discovered device starts that way
  // and gets corrected by the next snapshot once it pairs.
  function handleDeviceAdded(id, payload) {
    if (!id || !Kcd.isSafeDeviceId(id)) return
    var name = String((payload && typeof payload === "object" ? payload.name : payload) || id)
    var devs = io.devices.slice()
    for (var i = 0; i < devs.length; i++) {
      if (devs[i].id === id) return
    }
    devs.push({
      id: String(id), name: name, type: "phone", state: "UNPAIRED",
      connected: false, battery: null, media: null, lastSeen: "", signal: null
    })
    io.devices = devs
    io.daemonText = devs.length + " phone(s)"
  }

  function handleDeviceRemoved(id) {
    if (!id) return
    var kept = []
    for (var i = 0; i < io.devices.length; i++) {
      if (io.devices[i].id !== id) kept.push(io.devices[i])
    }
    if (kept.length === io.devices.length) return
    io.devices = kept
    io.daemonText = kept.length + " phone(s)"
  }

  function applyPairState(id, state) {
    if (!id) return
    var updated = []
    var found = false
    for (var i = 0; i < io.devices.length; i++) {
      var d = Object.assign({}, io.devices[i])
      if (d.id === id) {
        d.state = state
        found = true
      }
      updated.push(d)
    }
    if (found) io.devices = updated
  }

  // connectivity.update keeps the header's network label live instead of
  // frozen at whatever the last snapshot carried.
  function applySignal(id, payload) {
    if (!id) return
    var signal = Kcd.normalizeSignal(payload)
    if (!signal) return
    var updated = []
    var found = false
    for (var i = 0; i < io.devices.length; i++) {
      var d = Object.assign({}, io.devices[i])
      if (d.id === id) {
        d.signal = signal
        found = true
      }
      updated.push(d)
    }
    if (found) io.devices = updated
  }

  // Instant 0ms connect/disconnect handling: the watch event mutates the
  // in-memory devices list directly, so the UI flips without a CLI
  // round-trip.
  function handleDeviceDisconnected(id, timestamp) {
    if (!id) return
    var updated = []
    var found = false
    for (var i = 0; i < io.devices.length; i++) {
      var d = Object.assign({}, io.devices[i])
      if (d.id === id) {
        d.connected = false
        if (timestamp) d.lastSeen = timestamp
        found = true
      }
      updated.push(d)
    }
    if (found) {
      io.devices = updated
      if (io.deviceId === id) {
        io.lastSeenText = timestamp ? Kcd.formatLastSeen(timestamp) : "Just now"
        // Freeze media so the playhead can't ghost-creep on an offline
        // phone (daemonUp stays true; liveTrack gating can't do this).
        io.track = null
      }
    }
  }

  function handleDeviceConnected(id, timestamp, payload) {
    if (!id) return
    var updated = []
    var found = false
    for (var i = 0; i < io.devices.length; i++) {
      var d = Object.assign({}, io.devices[i])
      if (d.id === id) {
        d.connected = true
        d.lastSeen = timestamp || new Date().toISOString()
        found = true
      }
      updated.push(d)
    }
    if (!found) {
      // Connected before we ever saw device.added: adopt it from the
      // event payload so the list never waits on the next snapshot.
      io.handleDeviceAdded(id, payload)
      updated = io.devices
      found = true
    }
    io.devices = updated
    if (io.deviceId === id) {
      io.lastSeenText = "Now"
    }
  }

  function runTile(tile) {
    var cmd = Kcd.tileCommand(tile, io.deviceId)
    if (!cmd) return
    if ((tile === "ping" || tile === "ring") && io.deviceId === "") return
    Quickshell.execDetached(cmd)
  }

  // Revoke trust for the selected phone. No local state change: the
  // daemon publishes device.removed and applyEvent drops the device, so
  // the panel reaches the unpaired state on its own.
  function unpairDevice() {
    var cmd = Kcd.unpairCommand(io.deviceId)
    if (!cmd) return
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
    // A failed watch is proof the daemon isn't answering, so the probe is
    // done even with no CLI one-shot left to say so (otherwise uiState
    // would sit in "ready" forever with a dead daemon).
    io.daemonProbed = true
    io.daemonUp = false
    if (!io.installOk) return
    if (io.watchRestartRequested) {
      // Deliberate bounce from reconnectWatch(): straight back up, no backoff.
      io.watchRestartRequested = false
      io.watchAlive = true
      return
    }
    io.daemonText = "kcd — reconnecting…"
    io.watchBackoffMs = Math.min(io.watchBackoffMs * 2, 30000)
    io.watchRestartTimer.restart()
  }

  // Wedge guard: the version probe that hasn't returned 20s after launch
  // is reaped and marked done, so a wedged spawn can never block future
  // refreshes. Sleeps unless a probe is in flight.
  property Timer ioTimeout: Timer {
    interval: 5000
    repeat: true
    running: io.versionProc.running
    onTriggered: {
      if (io.ioStartMs === 0 || Date.now() - io.ioStartMs < 20000) return
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

  // The plugin's only live channel: the daemon pushes a full state
  // snapshot on connect and every later change as an event, so no CLI
  // state reads exist. `watchAlive` (never `running` directly) is flipped
  // so the installOk gate binding stays intact.
  property Process watchProc: Process {
    running: io.installOk && io.watchAlive
    command: ["kcd", "watch", "--json", "--events", "device.added,device.removed,device.connected,device.disconnected,battery.update,mpris.update,connectivity.update,pair.accepted,pair.requested,pair.rejected"]
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

  property Process versionProc: Process {
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: io.onVersionOutput(text)
    }
    onExited: function(exitCode) {
      io.installProbed = true
      // Installed-ness comes from the exit code alone: exit 0 means the
      // binary runs. The version string only feeds the footer — a future
      // format change must never strand the panel in "missing" again.
      if (exitCode !== 0) {
        io.installOk = false
        io.versionOk = false
      } else {
        io.installOk = true
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
