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
  // Seek target ms while a seek is in flight, -1 otherwise. Cleared by the
  // next position report (mpris.update or snapshot), never by a timer.
  property double seekHoldMs: -1
  readonly property double displayPos: io.seekHoldMs >= 0 ? io.seekHoldMs : io.anchorPos()
  property string lastSeenText: "—"
  property string daemonText: "starting…"
  // "—" until the version probe lands: never a fake version. In the
  // missing state the footer reads "kcd —".
  property string kcdVersion: "—"
  property bool versionOk: false
  // Verification key from the last pair.requested, shown while pairing.
  property string verificationKey: ""
  // The candidate awaiting the owner's decision. Held until accepted or
  // refused, so the code on screen always belongs to a real request.
  property string pendingPairId: ""
  property string pendingPairName: ""
  // True once the daemon confirms it is discoverable for pairing. The
  // process starting is not proof; kcd prints the transition.
  property bool advertising: false
  // Set once advertising has actually been confirmed, so an exit before
  // that means the build is too old for --advertise-only rather than the
  // owner cancelling.
  property bool pairAdvertised: false
  // Set when we stop the process ourselves, so a deliberate cancel is not
  // mistaken for a failure.
  property bool pairStopping: false
  // Shown instead of silently doing nothing on a kcd without the flag.
  property string pairNotice: ""
  property bool installOk: false
  property bool installProbed: false
  property bool daemonUp: false
  property bool daemonProbed: false
  property bool watchAlive: true
  // True between a stream dying and the next one starting, so one dead
  // stream arms backoff once.
  property bool watchDead: false
  // Set by reconnectWatch() so the death path it triggers restarts at
  // once instead of backing off; cleared on use.
  property bool watchRestartRequested: false
  property int watchBackoffMs: 2000
  // True while the phone's storage is mounted. The daemon owns this: it
  // arrives in the state.snapshot device summary and flips via the
  // sftp.mounted / sftp.unmounted events.
  readonly property bool storageMounted: autoDevice ? autoDevice.storageMounted === true : false
  property double ioStartMs: 0
  // Pairing advertisement (`kcd pair --advertise-only`): true while the
  // process runs. `advertising` is the stronger signal: it turns true only
  // once kcd confirms the daemon is discoverable.
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

  // Start pairing from a click: advertise, or cancel an advertisement in
  // progress. No device id, and nothing is accepted implicitly -- candidates
  // arrive as pair.requested events and wait for the owner.
  function togglePairing() {
    if (pairProc.running) {
      io.stopAdvertising()
      return
    }
    if (!io.installOk || !io.daemonUp) {
      io.refresh()
      return
    }
    io.pairAdvertised = false
    io.pairStopping = false
    io.pairNotice = ""
    pairProc.command = Kcd.pairCommand()
    pairProc.running = true
  }

  function stopAdvertising() {
    if (pairProc.running) io.pairStopping = true
    if (pairProc.running) pairProc.running = false
    io.advertising = false
  }

  // {"advertising":true|false} is the only proof the daemon is actually
  // discoverable; ignore anything else the CLI prints.
  function onAdvertiseOutput(text) {
    var state = Kcd.parseAdvertiseOutput(text)
    if (state === null) return
    io.advertising = state
    if (state === true) io.pairAdvertised = true
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
    io.seekHoldMs = -1
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
    return io.posAt(io.clockMs)
  }

  // Position at a given wall-clock ms. The clock must never predate the
  // sample: a ticker that hasn't ticked yet (freshly opened panel) would
  // otherwise rewind the anchor to 0 and turn a drag into an overshoot.
  function posAt(now) {
    // liveTrack (daemon-gated), never the raw cache: a dead daemon must
    // freeze the readout instead of creeping on stale data.
    if (!io.liveTrack) return 0
    var base = Number(io.liveTrack.pos) || 0
    if (io.liveTrack.isPlaying === true && Number(io.liveTrack.posAnchorMs) > 0) {
      base += Math.max(0, now - Number(io.liveTrack.posAnchorMs))
    }
    var len = Number(io.liveTrack.length) || 0
    if (len > 0) base = Math.min(len, base)
    return Math.max(0, base)
  }

  // A freshly opened panel has a ticker that hasn't ticked: seed the clock
  // so the first paint already interpolates instead of showing the sample.
  onPanelOpenChanged: {
    if (io.panelOpen) io.clockMs = Date.now()
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
      io.handlePairRequested(event.deviceId, event.payload)
    } else if (type === "pair.accepted") {
      io.clearPendingPair()
      io.stopAdvertising()
      io.applyPairState(event.deviceId, "PAIRED")
    } else if (type === "pair.rejected") {
      io.clearPendingPair()
      io.applyPairState(event.deviceId, "UNPAIRED")
    } else if (type === "connectivity.update") {
      io.applySignal(event.deviceId, event.payload)
    } else if (type === "sftp.mounted") {
      io.applyStorageMounted(event.deviceId, true)
    } else if (type === "sftp.unmounted") {
      io.applyStorageMounted(event.deviceId, false)
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
      io.seekHoldMs = -1
      io.setTrack(Kcd.normalizeTrack(event.payload))
    }
  }

  // First-seen device. Newer daemons send the whole device summary as the
  // payload, so use it rather than guessing; kcd < that sends a bare name
  // string, where the daemon reports strangers as UNPAIRED and disconnected
  // (no auto-dial) and the next snapshot corrects the rest.
  function handleDeviceAdded(id, payload) {
    if (!id || !Kcd.isSafeDeviceId(id)) return
    var devs = io.devices.slice()
    for (var i = 0; i < devs.length; i++) {
      if (devs[i].id === id) return
    }
    var dev = null
    if (payload && typeof payload === "object") {
      dev = Kcd.normalizeDevice(payload)
    }
    if (!dev) {
      dev = {
        id: String(id),
        name: String((payload && typeof payload === "object" ? payload.name : payload) || id),
        type: "phone", state: "UNPAIRED", connected: false,
        battery: null, media: null, lastSeen: "", signal: null, storageMounted: false
      }
    }
    devs.push(dev)
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

  // The daemon owns SFTP mount state: it lands in the snapshot summary and
  // flips here, so the Files tile never inspects the host's mount table.
  function applyStorageMounted(id, mounted) {
    if (!id) return
    var updated = []
    var found = false
    for (var i = 0; i < io.devices.length; i++) {
      var d = Object.assign({}, io.devices[i])
      if (d.id === id) {
        d.storageMounted = mounted === true
        found = true
      }
      updated.push(d)
    }
    if (found) io.devices = updated
  }

    // A phone asked to pair while we were advertising. Nothing is trusted
  // yet: hold the candidate and its code so the owner can compare, and
  // wait for an explicit accept or refuse.
  function handlePairRequested(id, payload) {
    if (!id || !Kcd.isSafeDeviceId(id)) return
    var p = payload || {}
    io.pendingPairId = String(id)
    io.pendingPairName = String(p.name || id)
    io.verificationKey = String(p.verificationKey || "")
  }

  function clearPendingPair() {
    io.pendingPairId = ""
    io.pendingPairName = ""
    io.verificationKey = ""
  }

  // Owner confirmed the code: accept exactly that device. Any other
  // candidate still has to be accepted on its own.
  function acceptPendingPair() {
    if (io.pendingPairId === "") return
    var cmd = Kcd.acceptPairCommand(io.pendingPairId)
    if (!cmd) return
    Quickshell.execDetached(cmd)
  }

  // Owner refused, or the request went stale: send the rejection so the
  // phone stops offering, then keep advertising for the real device.
  function rejectPendingPair() {
    if (io.pendingPairId === "") return
    var cmd = Kcd.rejectPairCommand(io.pendingPairId)
    if (cmd) Quickshell.execDetached(cmd)
    io.clearPendingPair()
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
    if (tile === "files") {
      io.toggleStorage()
      return
    }
    var cmd = Kcd.tileCommand(tile, io.deviceId)
    if (!cmd) return
    if (tile === "ring" && io.deviceId === "") return
    Quickshell.execDetached(cmd)
  }

  // The Files tile toggles: mount when nothing is mounted, unmount when
  // the phone's storage is live. No cooldown needed -- mount is idempotent
  // upstream, so a repeat tap just re-opens the file manager.
  function toggleStorage() {
    if (io.deviceId === "") return
    var mode = io.storageMounted ? "unmount" : "mount"
    Quickshell.execDetached(["bash", io.pluginDir + "/kcd-sftp.sh", mode, io.deviceId])
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

  // Seek from the card's wave drag: the drag names an absolute target,
  // the CLI only moves relative, so send the delta from the live anchor.
  // Fire-and-forget like every other transport action; the hold above
  // covers the round-trip, and the daemon's next report is confirmation.
  function mediaSeek(positionMs) {
    if (!io.liveConnected || io.deviceId === "") return
    // A player that denies seeking (streams) must never receive one: the
    // daemon would resolve against nothing and the drag would lie.
    if (io.liveTrack && io.liveTrack.canSeek === false) return
    var target = Math.max(0, Number(positionMs) || 0)
    // Fresh stamp, never the ticker: the whole point is the ticker may be
    // stale at the moment of the drag.
    var cmd = Kcd.seekCommand(io.deviceId, target - io.posAt(Date.now()))
    if (!cmd) return
    io.seekHoldMs = target
    Quickshell.execDetached(cmd)
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

  // Self-heal while open: a missing binary or a silent daemon is
  // re-probed every 10s, so reinstalls and outages recover without a tap.
  // The closed-panel guarantee is the `running` binding, not discipline:
  // panelOpen false stops the timer, and so does leaving missing/down.
  property Timer downProbeTimer: Timer {
    interval: 10000
    repeat: true
    running: io.panelOpen && (io.uiState === "missing" || io.uiState === "down")
    onTriggered: {
      io.refresh()
    }
  }

  property Timer watchRestartTimer: Timer {
    interval: io.watchBackoffMs
    repeat: false
    onTriggered: {
      io.watchAlive = true
    }
  }

  // Spawn watchdog: a watch (re)start that yields no line in time is a
  // silent spawn failure (a missing binary reports no exit, wedging
  // running=true with no process and no retry). Disarmed by the first
  // line, so steady state adds zero timers.
//
  // The interval is generous because a cold start goes through socket
  // activation: connecting can block while the daemon comes up, and a 10s
  // window was short enough to trip on a healthy-but-slow start.
  //
  // It flips watchAlive, never `watchProc.running`: that property is bound
  // to installOk && watchAlive, and assigning to it would strip the binding
  // so the backoff restart could never bring the stream back.
  property Timer watchStreamGuard: Timer {
    interval: 30000
    repeat: false
    onTriggered: {
      io.watchAlive = false
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
    // Dropping the stream (the guard, or a real exit) can reach this twice
    // for one dead stream. Only the first call may arm backoff, or the delay
    // doubles faster than intended. Reset by the stream actually starting.
    if (io.watchDead) return
    io.watchDead = true
    io.watchAlive = false
    if (io.watchRestartRequested) {
      // Deliberate bounce from reconnectWatch() (panel open, Retry, pair
      // exit): straight back up with the UI untouched. Marking the daemon
      // down here painted the down page on every healthy open until the
      // next snapshot landed, a flash under fast clicking.
      io.watchRestartRequested = false
      io.watchAlive = true
      return
    }
    // A failed watch is proof the daemon isn't answering, so the probe is
    // done even with no CLI one-shot left to say so (otherwise uiState
    // would sit in "ready" forever with a dead daemon).
    io.daemonProbed = true
    io.daemonUp = false
    if (!io.installOk) return
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


  // Panel-open and retry-tap refreshes, downProbeTimer below, intake
  // top-ups, and the watch lifecycle (plus its spawn guard) are the only
  // re-probe paths: installing kcd is picked up on the next open, retry,
  // or probe tick, and the daemon's return arrives as a watch snapshot.
  // No timer runs while the panel is closed.

  // The plugin's only live channel: the daemon pushes a full state
  // snapshot on connect and every later change as an event, so no CLI
  // state reads exist. `watchAlive` (never `running` directly) is flipped
  // so the installOk gate binding stays intact.
  property Process watchProc: Process {
    running: io.installOk && io.watchAlive
    command: ["kcd", "watch", "--json", "--events", "device.added,device.removed,device.connected,device.disconnected,battery.update,mpris.update,connectivity.update,sftp.mounted,sftp.unmounted,pair.accepted,pair.requested,pair.rejected"]
    stdout: SplitParser {
      onRead: function(data) { io.noteWatchLine(); io.handleWatchLine(data) }
    }
    onRunningChanged: {
      if (running) {
        io.watchDead = false
        io.watchStreamGuard.restart()
      }
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

  // Managed `kcd pair --advertise-only --json`: makes the daemon
  // discoverable and accepts nothing. Captured (not detached) because the
  // process is the advertisement's lifetime -- the owner cancels it, and a
  // successful pair must stop it -- and because `advertising` is only true
  // once kcd confirms the transition rather than merely started.
  property Process pairProc: Process {
    running: false
    stdout: SplitParser {
      onRead: function(data) { io.onAdvertiseOutput(data) }
    }
    onExited: function(exitCode) {
      io.advertising = false
      // Never confirmed advertising and we did not ask it to stop: this
      // build has no --advertise-only, so say so instead of appearing to
      // do nothing.
      if (!io.pairAdvertised && !io.pairStopping) {
        io.pairNotice = "This kcd build cannot advertise for pairing. Update it, or pair from a terminal: kcd pair"
      }
      io.pairStopping = false
      io.clearPendingPair()
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
