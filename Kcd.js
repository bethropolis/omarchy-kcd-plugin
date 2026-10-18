// Pure kcd data helpers: CAPITALIZED --json keys and lowercase IPC keys
// normalized here. Qt-free for node unit tests; QML owns all Process IO.

// Device IDs are daemon-supplied and untrusted: never reach a shell.
// Dash is escaped so the class is not a `.`-to-`:` range admitting / and @.
function isSafeDeviceId(id) {
  return /^[A-Za-z0-9_.:\-]+$/.test(String(id || ""))
}

// Normalize one device entry from either wire shape.
function normalizeDevice(entry) {
  if (!entry || typeof entry !== "object") return null
  var id = entry.id !== undefined && entry.id !== null ? entry.id : entry.ID
  var name = entry.name !== undefined && entry.name !== null ? entry.name : entry.Name
  var type = entry.type !== undefined && entry.type !== null ? entry.type : entry.Type
  var state = entry.state !== undefined && entry.state !== null ? entry.state : entry.State
  var connected = entry.connected !== undefined && entry.connected !== null ? entry.connected : entry.Connected
  if (id === undefined || id === null || String(id) === "") return null
  if (!isSafeDeviceId(id)) return null
  return {
    id: String(id),
    name: String(name !== undefined && name !== null ? name : id),
    type: String(type !== undefined && type !== null ? type : "phone"),
    state: String(state !== undefined && state !== null ? state : "UNKNOWN"),
    connected: connected === true,
    // Enriched summaries (devices --json, state.snapshot) embed cached
    // sub-states; absent (omitempty) when the daemon has nothing cached.
    battery: normalizeBattery(entry.battery !== undefined ? entry.battery : entry.Battery),
    media: normalizeTrack(entry.media !== undefined ? entry.media : entry.Media),
    // last_seen is an ISO timestamp string ("" when never seen).
    lastSeen: String(entry.last_seen !== undefined && entry.last_seen !== null ? entry.last_seen : (entry.lastSeen !== undefined && entry.lastSeen !== null ? entry.lastSeen : (entry.LastSeen || ""))),
    // signal is the daemon's connectivity report ({ signalStrengths: {...} })
    // reduced to a display label, or null when unreported.
    signal: normalizeSignal(entry.signal !== undefined ? entry.signal : entry.Signal),
    // SFTP mount state from sftp.mounted/unmounted events and the summary
    // block, omitted entirely when nothing is mounted (absent means false).
    storageMounted: isStorageMounted(entry.sftp !== undefined ? entry.sftp : entry.Sftp)
  }
}

// The `sftp` summary block is { mounted: true, mountPoint: "..." } and is
// omitted unless a mount is live. Anything else means "not mounted".
function isStorageMounted(sftp) {
  if (!sftp || typeof sftp !== "object") return false
  return sftp.mounted === true
}

// Normalize an embedded { charge, charging } battery summary (or the
// {"charge":N,"charging":B} battery --json object). Null when absent.
function normalizeBattery(obj) {
  if (!obj || typeof obj !== "object") return null
  var charge = obj.charge !== undefined && obj.charge !== null ? obj.charge : obj.Charge
  var charging = obj.charging !== undefined && obj.charging !== null ? obj.charging : obj.Charging
  var n = Number(charge)
  if (!isFinite(n) || n < 0) return null
  return { charge: Math.round(n), charging: charging === true }
}

// Display label from the first signalStrengths entry, or null when
// unreported ("Unknown" is the daemon zero value, not information).
function normalizeSignal(obj) {
  if (!obj || typeof obj !== "object") return null
  var strengths = obj.signalStrengths !== undefined && obj.signalStrengths !== null ? obj.signalStrengths : obj.SignalStrengths
  if (!strengths || typeof strengths !== "object") return null
  var keys = Object.keys(strengths)
  if (keys.length === 0) return null
  var s = strengths[keys[0]] || {}
  var detail = s.networkDetailedType !== undefined && s.networkDetailedType !== null ? s.networkDetailedType : s.NetworkDetailedType
  var type = s.networkType !== undefined && s.networkType !== null ? s.networkType : s.NetworkType
  var label = String(detail || type || "")
  if (label === "" || /^unknown$/i.test(label)) return null
  return {
    label: label,
    strength: numOr(s.signalStrength !== undefined ? s.signalStrength : s.SignalStrength, -1)
  }
}

// "Last seen: …" line for an ISO timestamp. "Now" under 90s, relative
// minutes/hours after that, short date beyond a day. Garbage → "—".
function formatLastSeen(iso) {
  var t = Date.parse(String(iso || ""))
  if (isNaN(t)) return "—"
  var mins = Math.max(0, Math.floor((Date.now() - t) / 60000))
  if (mins < 2) return "Now"
  if (mins < 60) return mins + "m ago"
  var hours = Math.floor(mins / 60)
  if (hours < 24) return hours + "h ago"
  var d = new Date(t)
  function pad(n) { return ("0" + n).slice(-2) }
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
}
// Playing is always fresh; cached paused entries older than 10s must not
// resurrect ghost tracks. Payloads without mediaAgeMs count as fresh.
function isFreshMedia(track) {
  if (!track) return false
  if (track.isPlaying === true) return true
  var age = Number(track.mediaAgeMs)
  if (!isFinite(age) || age < 0) return true
  return age <= 10000
}

// Normalize an already-parsed device array (e.g. state.snapshot payload).
function normalizeDevices(list) {
  var out = []
  if (!(list instanceof Array)) return out
  for (var i = 0; i < list.length; i++) {
    var dev = normalizeDevice(list[i])
    if (dev !== null) out.push(dev)
  }
  return out
}

// Paired AND connected only: strangers report UNPAIRED and an unpaired TCP
// link is useless, so auto-select requires state==PAIRED.
function isUsableDevice(dev) {
  if (!dev) return false
  if (dev.connected !== true) return false
  return String(dev.state || "").toUpperCase() === "PAIRED"
}

// First paired device regardless of connection: distinguishes offline
// (patience) from never-paired (pair request).
function pickPairedDevice(devices) {
  if (!devices || devices.length === 0) return null
  for (var i = 0; i < devices.length; i++) {
    var dev = devices[i]
    if (dev && String(dev.state || "").toUpperCase() === "PAIRED") return dev
  }
  return null
}

// First paired+connected device, else null. Anything else shows the
// unpaired state instead of auto-selecting.
function pickAutoDevice(devices) {
  if (!devices || devices.length === 0) return null
  for (var i = 0; i < devices.length; i++) {
    if (isUsableDevice(devices[i])) return devices[i]
  }
  return null
}

// Normalize one mpris status entry from either wire shape.
function normalizeTrack(entry) {
  if (!entry || typeof entry !== "object") return null
  function pick() {
    for (var i = 0; i < arguments.length; i++) {
      var key = arguments[i]
      if (entry[key] !== undefined && entry[key] !== null) return entry[key]
    }
    return undefined
  }
  var title = pick("title", "Title")
  if (title === undefined || String(title) === "") return null
  return {
    player: String(pick("player", "Player") || ""),
    title: String(title),
    artist: String(pick("artist", "Artist") || ""),
    album: String(pick("album", "Album") || ""),
    albumArtUrl: String(pick("albumArtUrl", "AlbumArtUrl") || ""),
    // artPending: fetch in flight with intentionally empty URL.
    artPending: pick("artPending", "ArtPending") === true,
    isPlaying: pick("isPlaying", "IsPlaying") === true,
    pos: numOr(pick("pos", "Pos"), 0),
    // posAnchorMs: wall-clock Unix millis when pos was sampled. Absent
    // (0) on paused/legacy states — then hold pos frozen.
    posAnchorMs: numOr(pick("posAnchorMs", "PosAnchorMs"), 0),
    // mediaAgeMs: ms since the phone reported (snapshot only, -1
    // unknown), feeding the staleness rule in isFreshMedia.
    mediaAgeMs: pick("mediaAgeMs", "MediaAgeMs") === undefined ? -1 : numOr(pick("mediaAgeMs", "MediaAgeMs"), -1),
    length: numOr(pick("length", "Length"), 0),
    volume: numOr(pick("volume", "Volume"), -1),
    // canSeek arrives on newer daemons; absent means unknown, which seeks
    // (the old behavior) rather than disabling seeking everywhere.
    canSeek: pick("canSeek", "CanSeek") !== false,
    deviceId: String(pick("deviceId", "DeviceId") || "")
  }
}

function numOr(value, fallback) {
  var n = Number(value)
  return isFinite(n) && n >= 0 ? n : fallback
}

// Qt buffers remote art with no byte limit and the daemon forwards peer
// URLs uncapped: file:// only. kdeconnect:/ URIs also show a placeholder.
function isUsableArt(url) {
  return String(url || "").indexOf("file://") === 0
}

// One watch --json stdout line: { event } for real events, { skip } for
// the ack, blanks, and garbage.
function parseWatchLine(line) {
  var raw = String(line || "").trim()
  if (raw === "") return { skip: true }
  var parsed = null
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return { skip: true }
  }
  if (!parsed || typeof parsed !== "object") return { skip: true }
  if (parsed.type === undefined || parsed.type === null) return { skip: true }
  return {
    event: {
      type: String(parsed.type),
      deviceId: String(parsed.deviceId || ""),
      timestamp: String(parsed.timestamp || ""),
      payload: parsed.payload !== undefined ? parsed.payload : null
    }
  }
}

// Absolute path of the kcd config file. Respects XDG_CONFIG_HOME,
// falls back to ~/.config (nvim expands a leading ~ if all else fails).
function configTomlPath(home, xdgConfigHome) {
  var base = xdgConfigHome ? String(xdgConfigHome) : ""
  if (base === "" && home) base = String(home) + "/.config"
  if (base === "") base = "~/.config"
  return base + "/kcd/kcd.toml"
}

function watchCommand(events) {
  var cmd = ["kcd", "watch", "--json"]
  if (events && events.length > 0) {
    cmd.push("--events", events.join(","))
  }
  return cmd
}

// Tiles that spawn kcd directly. Files is absent: it needs kcd-sftp.sh,
// so toggleStorage() runs it.
function tileCommand(tile, deviceId) {
  var id = String(deviceId || "")
  if (tile === "ring") return ["kcd", "findmyphone", id]
  if (tile === "clipboard") return id !== "" ? ["kcd", "clipboard", id] : ["kcd", "clipboard"]
  return null
}

function mprisCommand(action, deviceId) {
  var id = String(deviceId || "")
  var cmd = ["kcd", "mpris", action]
  if (id !== "") cmd = ["kcd", "mpris", action, "--device", id]
  return cmd
}

// Volume step from the current level: null when unknown (-1), refusing
// boundary no-ops at 0/100 so muted/maxed wheels spawn nothing.
function stepVolume(current, delta) {
  var c = Math.round(Number(current))
  if (!isFinite(c) || c < 0) return null
  var v = Math.max(0, Math.min(100, c + Math.round(Number(delta) || 0)))
  return v === c ? null : v
}

// Absolute level, flags first. Null or out-of-range spawns nothing:
// Number(null) is 0, so guarding here means never mute by accident.
function volumeCommand(deviceId, volume) {
  if (volume === null || volume === undefined) return null
  var id = String(deviceId || "")
  var v = Math.round(Number(volume))
  if (!isSafeDeviceId(id) || !isFinite(v) || v < 0 || v > 100) return null
  return ["kcd", "mpris", "volume", "--device", id, String(v)]
}

// Relative seek in whole seconds; the CLI has no absolute mode (bare 60
// means +60s). Zero deltas return null, never seek-to-0.
function seekCommand(deviceId, offsetMs) {
  var id = String(deviceId || "")
  if (!isSafeDeviceId(id)) return null
  var secs = Math.round(Number(offsetMs) / 1000)
  if (!isFinite(secs) || secs === 0) return null
  var offset = (secs > 0 ? "+" : "-") + String(Math.abs(secs)) + "s"
  return ["kcd", "mpris", "seek", "--device", id, offset]
}

// Advertise discoverability without accepting anything; candidates arrive
// as pair.requested for the owner to decide per device.
function pairCommand() {
  return ["kcd", "pair", "--advertise-only", "--json"]
}

// Accept one specific pending request. Rejects nothing implicitly: the id is
// the device the owner confirmed.
function acceptPairCommand(deviceId) {
  var id = String(deviceId || "")
  if (!isSafeDeviceId(id)) return null
  return ["kcd", "pair", id]
}

// Refuse a pending request. kcd documents `unpair` as the reject path for a
// candidate reported by pair_listen.
function rejectPairCommand(deviceId) {
  var id = String(deviceId || "")
  if (!isSafeDeviceId(id)) return null
  return ["kcd", "unpair", id]
}

// Parse one line of `kcd pair --advertise-only --json`.
// Returns true/false for the advertising transitions, null for anything else.
function parseAdvertiseOutput(text) {
  var raw = String(text || "").trim()
  if (raw === "") return null
  var parsed = null
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed !== "object") return null
  if (parsed.advertising === true) return true
  if (parsed.advertising === false) return false
  return null
}

// Rejection packet plus registry drop. No local state change: the daemon
// publishes device.removed and the panel follows the event.
function unpairCommand(deviceId) {
  var id = String(deviceId || "")
  if (!isSafeDeviceId(id)) return null
  return ["kcd", "unpair", id]
}

// Spawns kcd-sftp.sh in both directions; kcd owns credential wait,
// mount, file-manager hand-off, and unmount cleanup.
function mountCommand(deviceId) {
  var id = String(deviceId || "")
  if (!isSafeDeviceId(id)) return null
  return ["kcd", "sftp", "mount", id]
}

function unmountCommand(deviceId) {
  var id = String(deviceId || "")
  if (!isSafeDeviceId(id)) return null
  return ["kcd", "sftp", "unmount", id]
}

// Single file only (the CLI rejects directories); the argv contract
// kcd-share.sh fulfills.
function shareCommand(deviceId, filePath) {
  var id = String(deviceId || "")
  var path = String(filePath || "")
  if (id === "" || path === "") return null
  return ["kcd", "share", id, path]
}

// Panel closes first, then the script captures (grim) and shares. The
// QML caller resolves the script path (it knows $HOME).
function screenshotShareCommand(scriptPath, deviceId, deviceName) {
  var script = String(scriptPath || "")
  var id = String(deviceId || "")
  var name = String(deviceName || "")
  if (script === "" || id === "" || name === "") return null
  return ["bash", script, id, name]
}

// Every icon glyph rendered, as codepoints: the probe covers exactly
// this set, so list new glyphs here.
var ICON_CODEPOINTS = "F001 F00C F00D F011 F011C F013 F021 F028 F030 F048 F04B F04C F04D F051 F052 F071 F07B F0C1 F0EA F10B F1D8 F1E6 F1EB F0079 F007A F007B F007C F007D F007E F007F F0080 F0081 F0082 F0083 F0085 F0086 F0087 F0088 F0089 F008A F008B F089C F089D F089E"

// Preferring the theme family: unchanged when it covers all glyphs, else
// fontconfig substitutes. Argv only, so spaced names need no quoting.
function iconProbeCommand(themeFontFamily) {
  var family = String(themeFontFamily || "monospace")
  return ["fc-match", "-f", "%{family[0]}", ":family=" + family + ":charset=" + ICON_CODEPOINTS]
}

// First stdout line trimmed; unusable output keeps the theme font.
function parseIconProbeOutput(text) {
  var line = String(text || "").split("\n")[0]
  if (!line) return ""
  line = line.replace(/^\s+|\s+$/g, "")
  return line
}

// Probed covering family once known, else the theme font: one shared
// picker so the fallback cannot drift per site.
function iconFont(probed, fallback) {
  var p = String(probed || "")
  return p !== "" ? p : String(fallback || "")
}

// Split the icon-plus-figures label on the first space (space stays with
// figures). One Text cannot hold two families.
function barLabelRuns(label) {
  var s = String(label || "")
  var at = s.indexOf(" ")
  if (at < 0) return { icon: "", figures: s }
  return { icon: s.slice(0, at), figures: s.slice(at) }
}

// Nerd Font battery ladder, same convention as omarchy.power: the icon
// itself encodes level + charging, so no bolt emoji is ever needed.
var BATTERY_CHARGING = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
var BATTERY_DISCHARGING = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]

function batteryLevelIndex(charge) {
  var n = Number(charge)
  if (!isFinite(n) || n < 0) return -1
  return Math.max(0, Math.min(9, Math.floor(n / 10)))
}

function batteryIcon(charge, charging) {
  var index = batteryLevelIndex(charge)
  if (index < 0) return "󰂃"
  return (charging === true ? BATTERY_CHARGING : BATTERY_DISCHARGING)[index]
}

function batteryText(charge, charging) {
  var n = Number(charge)
  if (!isFinite(n) || n < 0) return "--"
  return Math.round(n) + "%"
}

// m:ss / m:ss — "--:--" when length unknown.
function positionText(pos, length) {
  function fmt(ms) {
    var s = Math.max(0, Math.floor(Number(ms) / 1000))
    if (!isFinite(s)) return "--:--"
    return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2)
  }
  if (!isFinite(Number(length)) || Number(length) <= 0) return fmt(pos)
  return fmt(pos) + " / " + fmt(length)
}

function progress(pos, length) {
  var p = Number(pos)
  var l = Number(length)
  if (!isFinite(p) || !isFinite(l) || l <= 0) return 0
  return Math.max(0, Math.min(1, p / l))
}

// Keep the previous device first while it stays usable, so two phones
// don't flap auto-selection. A depinned device keeps natural order.
function stickDevice(devices, id) {
  if (!devices || devices.length === 0) return devices || []
  var want = String(id || "")
  if (want === "") return devices
  var at = -1
  for (var i = 0; i < devices.length; i++) {
    if (devices[i] && devices[i].id === want && isUsableDevice(devices[i])) {
      at = i
      break
    }
  }
  if (at <= 0) return devices
  var out = [devices[at]]
  for (var j = 0; j < devices.length; j++) {
    if (j !== at) out.push(devices[j])
  }
  return out
}

// vX.Y.Z with v prefix from `kcd version`, tolerating v-prefixed and
// bare formats. Null when unparseable.
function parseVersionOutput(text) {
  var m = String(text || "").match(/v?(\d+\.\d+\.\d+)/)
  return m ? "v" + m[1] : null
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeDevice: normalizeDevice,
    normalizeDevices: normalizeDevices,
    normalizeBattery: normalizeBattery,
    normalizeSignal: normalizeSignal,
    formatLastSeen: formatLastSeen,
    isFreshMedia: isFreshMedia,
    isUsableDevice: isUsableDevice,
    pickPairedDevice: pickPairedDevice,
    pickAutoDevice: pickAutoDevice,
    normalizeTrack: normalizeTrack,
    parseVersionOutput: parseVersionOutput,
    isSafeDeviceId: isSafeDeviceId,
    configTomlPath: configTomlPath,
    pairCommand: pairCommand,
    acceptPairCommand: acceptPairCommand,
    rejectPairCommand: rejectPairCommand,
    parseAdvertiseOutput: parseAdvertiseOutput,
    unpairCommand: unpairCommand,
    mountCommand: mountCommand,
    unmountCommand: unmountCommand,
    shareCommand: shareCommand,
    screenshotShareCommand: screenshotShareCommand,
    stickDevice: stickDevice,
    isUsableArt: isUsableArt,
    parseWatchLine: parseWatchLine,
    watchCommand: watchCommand,
    tileCommand: tileCommand,
    mprisCommand: mprisCommand,
    stepVolume: stepVolume,
    volumeCommand: volumeCommand,
    seekCommand: seekCommand,
    batteryText: batteryText,
    iconFont: iconFont,
    barLabelRuns: barLabelRuns,
    iconProbeCommand: iconProbeCommand,
    parseIconProbeOutput: parseIconProbeOutput,
    ICON_CODEPOINTS: ICON_CODEPOINTS,
    batteryIcon: batteryIcon,
    batteryLevelIndex: batteryLevelIndex,
    positionText: positionText,
    progress: progress
  }
}
