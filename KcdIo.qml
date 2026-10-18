import QtQuick
import Quickshell
import Quickshell.Io
import "Kcd.js" as Kcd

// kcd IO engine: every Process/Timer, all raw state, and only functions
// touching them. Non-visual; Panel.qml owns UI state.
QtObject {
  id: io

  // Input from Panel.qml (posTicker needs it; everything else is push).
  property bool panelOpen: false

  // Install dir beside the QML: single source for script spawn paths.
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.bethropolis.kcd"

  // ---- Icon font: theme family from Panel.qml; the bar injects late,
  // so a change re-probes.
  property string themeFontFamily: "monospace"
  // Probe result; empty until it lands, keeping the theme font.
  property string probedIconFont: ""
  // Icon family: probe result once known, theme family until then.
  readonly property string iconFontFamily: Kcd.iconFont(io.probedIconFont, io.themeFontFamily)

  onThemeFontFamilyChanged: io.startFontProbe()
  Component.onCompleted: io.startFontProbe()

  // One short-lived fontconfig spawn per theme-family change.
  function startFontProbe() {
    fontProbeProc.command = Kcd.iconProbeCommand(io.themeFontFamily)
    fontProbeProc.running = true
  }

  // ---- State
  property var devices: []
  readonly property var autoDevice: Kcd.pickAutoDevice(devices)
  // First paired device even when offline: separates offline from
  // never-paired.
  readonly property var pairedDevice: Kcd.pickPairedDevice(devices)
  readonly property string pairedName: pairedDevice ? String(pairedDevice.name) : "phone"
  readonly property string deviceId: autoDevice ? String(autoDevice.id) : ""
  readonly property string deviceName: autoDevice ? String(autoDevice.name) : "No phone"
  readonly property bool deviceConnected: autoDevice ? autoDevice.connected === true : false

  property int batteryCharge: -1
  property bool batteryCharging: false
  property var track: null
  property double clockMs: 0
  // Anchor stamp plus elapsed while playing (frozen otherwise, no anchor
  // holds last pos); the seek hold clears on the next report, never by timer.
  property double seekHoldMs: -1
  readonly property double displayPos: io.seekHoldMs >= 0 ? io.seekHoldMs : io.anchorPos()
  property string lastSeenText: "—"
  property string daemonText: "starting…"
  // "—" until the version probe lands: never a fake version. In the
  // missing state the footer reads "kcd —".
  property string kcdVersion: "—"
  property bool versionOk: false
  property string verificationKey: ""
  // Candidate awaiting the owner decision; held so the shown code belongs
  // to a real request.
  property string pendingPairId: ""
  property string pendingPairName: ""
  // True only once kcd confirms discoverability; starting the process
  // is not proof.
  property bool advertising: false
  // Confirmed advertising at least once: an earlier exit means a kcd too
  // old for --advertise-only.
  property bool pairAdvertised: false
  // Stopping the process ourselves is a cancel, not a failure.
  property bool pairStopping: false
  // Shown instead of silently doing nothing on a kcd without the flag.
  property string pairNotice: ""
  property bool installOk: false
  property bool installProbed: false
  property bool daemonUp: false
  property bool daemonProbed: false
  property bool watchAlive: true
  // One dead stream arms backoff once.
  property bool watchDead: false
  // Deliberate bounce: restart at once instead of backing off.
  property bool watchRestartRequested: false
  property int watchBackoffMs: 2000
  // Phone-side mount state from the snapshot summary, flipped by
  // sftp.mounted/unmounted events.
  readonly property bool storageMounted: autoDevice ? autoDevice.storageMounted === true : false
  property double ioStartMs: 0
  // Advertisement process lifetime; `advertising` is the stronger,
  // kcd-confirmed signal.
  readonly property bool pairing: pairProc.running
  readonly property bool startingDaemon: daemonProc.running

  // liveTrack is null whenever the daemon is unreachable, so stale state
  // never renders as live.
  readonly property var liveTrack: io.daemonUp ? io.track : null
  readonly property bool hasTrack: liveTrack !== null && liveTrack !== undefined
  // Read liveTrack once: its fields can disagree mid-transition.
  readonly property double trackLength: {
    if (liveTrack === null || liveTrack === undefined) return 0
    var l = Number(liveTrack.length)
    return isFinite(l) && l > 0 ? l : 0
  }
  readonly property bool usableArt: hasTrack && Kcd.isUsableArt(liveTrack.albumArtUrl)
  readonly property bool playing: hasTrack && liveTrack.isPlaying === true
  readonly property bool liveConnected: io.deviceConnected && io.daemonUp
  // "ready" until probes complete avoids a boot flash. Offline means
  // paired-but-unreachable: wait, don't re-pair.
  readonly property string uiState: {
    if (!io.installProbed || !io.daemonProbed) return "ready"
    if (!io.installOk) return "missing"
    if (!io.daemonUp) return "down"
    if (!io.autoDevice) return io.pairedDevice ? "offline" : "unpaired"
    return "ready"
  }

  // Closed-bar readout: battery icon encodes level plus charging.
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

  // All panel state arrives over the watch stream; a refresh re-checks
  // the binary and bounces the stream for a fresh snapshot.
  function refresh() {
    // Not latched: a stale installOk would blind reopen to a removed
    // binary. Flags hold during the probe, so no flash.
    if (!versionProc.running) {
      // sh wrapper so a missing binary exits 127 instead of wedging with
      // no onExited.
      versionProc.command = ["sh", "-c", "kcd --version"]
      versionProc.running = true
    }
    io.reconnectWatch()
  }

  // Bounce the stream for a fresh snapshot; the death path restarts it
  // at once with the UI untouched.
  function reconnectWatch() {
    if (!io.installOk || !io.watchAlive) return
    io.watchRestartTimer.stop()
    io.watchBackoffMs = 2000
    io.watchRestartRequested = true
    io.watchAlive = false
  }

  // Advertise, or cancel an advertisement in progress. Candidates arrive
  // as pair.requested for the owner.
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

  // Only {"advertising":true|false} proves discoverability; ignore the
  // rest of the CLI output.
  function onAdvertiseOutput(text) {
    var state = Kcd.parseAdvertiseOutput(text)
    if (state === null) return
    io.advertising = state
    if (state === true) io.pairAdvertised = true
  }

  // Primes kcd.socket (idempotent); the next probe/watch summons the
  // daemon and the panel wakes on its own.
  function startDaemon() {
    if (daemonProc.running || !io.installOk) return
    daemonProc.command = ["systemctl", "--user", "start", "kcd.socket"]
    daemonProc.running = true
  }

  // Authoritative full state: no partial list to top up, no empty-guard.
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
      // A connected phone was seen now by definition; the daemon stamp
      // only moves on (re)connect.
      if (ad.connected) io.lastSeenText = "Now"
      else if (ad.lastSeen) io.lastSeenText = Kcd.formatLastSeen(ad.lastSeen)
      else if (switched) io.lastSeenText = "—"
    }
    io.daemonText = devs.length > 0 ? "kcd — " + devs.length + " phone(s)" : "kcd — no phones"
  }

  // Grace period prevents card height flickering during track transitions.
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

  // Position at wall-clock ms; elapsed floors at 0 so a predated clock
  // never rewinds the anchor.
  function posAt(now) {
    // Daemon-gated: a dead daemon freezes the readout instead of
    // creeping on stale data.
    if (!io.liveTrack) return 0
    var base = Number(io.liveTrack.pos) || 0
    if (io.liveTrack.isPlaying === true && Number(io.liveTrack.posAnchorMs) > 0) {
      base += Math.max(0, now - Number(io.liveTrack.posAnchorMs))
    }
    var len = Number(io.liveTrack.length) || 0
    if (len > 0) base = Math.min(len, base)
    return Math.max(0, base)
  }

  // Seed the clock on open so the first paint already interpolates.
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

  // Newer daemons send the full device summary; older ones send a bare
  // name corrected by the next snapshot.
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

  // The daemon owns mount state, so the tile never inspects the host
  // mount table.
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

  // Hold the candidate and its code for owner comparison; nothing is
  // trusted yet.
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

  // Accept exactly the confirmed device; other candidates need their own
  // accept.
  function acceptPendingPair() {
    if (io.pendingPairId === "") return
    var cmd = Kcd.acceptPairCommand(io.pendingPairId)
    if (!cmd) return
    Quickshell.execDetached(cmd)
  }

  // Reject so the phone stops offering; keep advertising for the real
  // device.
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

  // Keeps the header network label live instead of frozen at the snapshot.
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

  // Mutate the device list in place so the UI flips with no CLI round-trip.
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
        // Freeze media: liveTrack gating alone can't stop ghost-creep on
        // an offline phone.
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
      // Adopt from the event payload so the list never waits on the next
      // snapshot.
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

  // Mount when unmounted, unmount when live. Mount is idempotent
  // upstream: no cooldown needed.
  function toggleStorage() {
    if (io.deviceId === "") return
    var mode = io.storageMounted ? "unmount" : "mount"
    Quickshell.execDetached(["bash", io.pluginDir + "/kcd-sftp.sh", mode, io.deviceId])
  }


  // No local state change: device.removed drops the device and the panel
  // follows.
  function unpairDevice() {
    var cmd = Kcd.unpairCommand(io.deviceId)
    if (!cmd) return
    Quickshell.execDetached(cmd)
  }

  // Spawn half only; Panel.qml guards, closes first, and resolves the
  // path. Bash survives a lost exec bit.
  function shareFile(deviceId, deviceName) {
    Quickshell.execDetached(["bash", io.pluginDir + "/kcd-share.sh", deviceId, deviceName])
  }

  // Mirrors shareFile; the script waits out the hide animation itself
  // before capturing.
  function screenshotShare(deviceId, deviceName) {
    Quickshell.execDetached(["bash", io.pluginDir + "/kcd-screenshot-share.sh", deviceId, deviceName])
  }



  function mediaAction(action) {
    Quickshell.execDetached(Kcd.mprisCommand(action, io.deviceId))
  }

  // Wheel step from the card: absolute level from the live volume, spawned
  // fire-and-forget; the daemon's next report is the confirmation.
  function adjustVolume(delta) {
    if (!io.liveConnected || io.deviceId === "") return
    if (!io.liveTrack) return
    var cmd = Kcd.volumeCommand(io.deviceId, Kcd.stepVolume(io.liveTrack.volume, delta))
    if (!cmd) return
    Quickshell.execDetached(cmd)
  }

  // The drag names an absolute target but the CLI moves relative: send
  // the delta. The hold covers the round-trip.
  function mediaSeek(positionMs) {
    if (!io.liveConnected || io.deviceId === "") return
    // Denied seeks (streams) resolve against nothing, so refuse them here.
    if (io.liveTrack && io.liveTrack.canSeek === false) return
    var target = Math.max(0, Number(positionMs) || 0)
    // Fresh stamp, never the ticker: the ticker may be stale mid-drag.
    var cmd = Kcd.seekCommand(io.deviceId, target - io.posAt(Date.now()))
    if (!cmd) return
    io.seekHoldMs = target
    Quickshell.execDetached(cmd)
  }

  // mpris.update fires only on real changes, so interpolate between them.
  property Timer trackClearTimer: Timer {
    interval: 2000
    repeat: false
    onTriggered: {
      io.track = null
    }
  }

  // Re-triggers the displayPos binding; not a clock itself.
  property Timer posTicker: Timer {
    interval: 100
    repeat: true
    running: io.panelOpen && io.playing
    onTriggered: {
      io.clockMs = Date.now()
    }
  }

  // Re-probe missing/down every 10s while open. The `running` binding
  // (not discipline) guarantees never-while-closed.
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

  // A (re)start with no line in time is a silent spawn failure: flip
  // watchAlive, never the bound watchProc.running (generous interval for slow starts).
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

  // Death path for real exits and silent failures: mark down, back off,
  // retry while installed.
  function noteWatchFailure() {
    // Latched: one dead stream arms backoff once (reset when a stream
    // starts).
    if (io.watchDead) return
    io.watchDead = true
    io.watchAlive = false
    if (io.watchRestartRequested) {
      // Requested bounces restart at once with the UI untouched: no
      // down-page flash.
      io.watchRestartRequested = false
      io.watchAlive = true
      return
    }
    // A dead watch proves the daemon down even with no CLI probe left
    // to say so.
    io.daemonProbed = true
    io.daemonUp = false
    if (!io.installOk) return
    io.daemonText = "kcd — reconnecting…"
    io.watchBackoffMs = Math.min(io.watchBackoffMs * 2, 30000)
    io.watchRestartTimer.restart()
  }

  // Reap a version probe wedged over 20s so it can never block
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


  // The only re-probe paths: opens, retries, probe ticks, intake
  // top-ups, watch lifecycle. Nothing runs while closed.

  // Sole live channel: full snapshot on connect, events after. Flip
  // watchAlive, never running, to keep the installOk gate.
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
      // Exit code alone decides installed-ness; the version string only
      // feeds the footer.
      if (exitCode !== 0) {
        io.installOk = false
        io.versionOk = false
      } else {
        io.installOk = true
      }
    }
  }

  // A missing fontconfig just leaves the theme font: nothing to guard
  // or retry.
  property Process fontProbeProc: Process {
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: io.probedIconFont = Kcd.parseIconProbeOutput(text)
    }
  }

  // Captured, not detached: the process lifetime is the advertisement,
  // and `advertising` turns true only on kcd's confirmation.
  property Process pairProc: Process {
    running: false
    stdout: SplitParser {
      onRead: function(data) { io.onAdvertiseOutput(data) }
    }
    onExited: function(exitCode) {
      io.advertising = false
      // Exit before confirming, unasked: a kcd too old for
      // --advertise-only. Say so instead of silence.
      if (!io.pairAdvertised && !io.pairStopping) {
        io.pairNotice = "This kcd build cannot advertise for pairing. Update it, or pair from a terminal: kcd pair"
      }
      io.pairStopping = false
      io.clearPendingPair()
      io.refresh()
    }
  }

  // Managed daemon start; short-lived.
  property Process daemonProc: Process {
    running: false
    onExited: function(exitCode) {
      io.refresh()
    }
  }
}
