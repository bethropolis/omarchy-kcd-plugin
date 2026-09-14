// Pure kcd data helpers for the Night Drive panel.
// Qt-free so it can be unit tested under node; QML owns all Process IO.
//
// Two wire shapes exist and both must be handled:
//   - `kcd <cmd> --json` prints Go structs with CAPITALIZED keys
//     (ID, Name, State, Connected).
//   - Raw IPC (`devices` over the socket) uses lowercase keys
//     (id, name, state, connected).
// Normalize everything to { id, name, type, state, connected } here.

// Normalize one device entry from either wire shape.
function normalizeDevice(entry) {
  if (!entry || typeof entry !== "object") return null
  var id = entry.id !== undefined && entry.id !== null ? entry.id : entry.ID
  var name = entry.name !== undefined && entry.name !== null ? entry.name : entry.Name
  var type = entry.type !== undefined && entry.type !== null ? entry.type : entry.Type
  var state = entry.state !== undefined && entry.state !== null ? entry.state : entry.State
  var connected = entry.connected !== undefined && entry.connected !== null ? entry.connected : entry.Connected
  if (id === undefined || id === null || String(id) === "") return null
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
    signal: normalizeSignal(entry.signal !== undefined ? entry.signal : entry.Signal)
  }
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

// Reduce a connectivity report ({ signalStrengths: { key: {
// networkType, networkDetailedType?, signalStrength } } }) to a display
// label from its first entry. Null when unreported — callers fall back
// to a generic "local network" line.
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
  // "Unknown" is the daemon's zero value, not information — treat it as
  // unreported so callers fall back to the generic line.
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
// Freshness rule for cached media (snapshot/summary carry mediaAgeMs;
// one-shot/watch payloads don't, and playing is always fresh). Stale
// paused entries must not resurrect ghost tracks on boot.
function isFreshMedia(track) {
  if (!track) return false
  if (track.isPlaying === true) return true
  var age = Number(track.mediaAgeMs)
  if (!isFinite(age) || age < 0) return true
  return age <= 10000
}

// Parse `kcd devices --json` stdout into normalized devices.
// Returns [] on any failure — callers treat empty as "no data yet".
function parseDevicesOutput(text) {
  var raw = String(text || "").trim()
  if (raw === "") return []
  var parsed = null
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return []
  }
  if (parsed === null || parsed === undefined) return []
  var list = parsed instanceof Array ? parsed : [parsed]
  return normalizeDevices(list)
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

// Usable means paired AND connected. Since the no-auto-dial fix the daemon
// reports discovered strangers as UNPAIRED/disconnected, and a raw TCP link
// without pairing can't do anything — so auto-select requires state==PAIRED
// (case-insensitive; wire strings are SCREAMING_SNAKE like "PAIRED").
function isUsableDevice(dev) {
  if (!dev) return false
  if (dev.connected !== true) return false
  return String(dev.state || "").toUpperCase() === "PAIRED"
}

// First paired device regardless of connection. Used to tell "paired
// but offline" (phone asleep, TCP down) apart from "never paired" —
// the former needs patience, not another pair request.
function pickPairedDevice(devices) {
  if (!devices || devices.length === 0) return null
  for (var i = 0; i < devices.length; i++) {
    var dev = devices[i]
    if (dev && String(dev.state || "").toUpperCase() === "PAIRED") return dev
  }
  return null
}

// Single-device framing: first paired+connected device wins, else null.
// Mirrors `kcd devices --connected` (usable = paired+connected). Known but
// unpaired/disconnected devices are NOT auto-selected — callers show the
// unpaired state instead.
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
    // artPending: fetch in flight, URL intentionally empty — render the
    // placeholder with no special casing (never a kdeconnect:/ URI now).
    artPending: pick("artPending", "ArtPending") === true,
    isPlaying: pick("isPlaying", "IsPlaying") === true,
    pos: numOr(pick("pos", "Pos"), 0),
    // posAnchorMs: wall-clock Unix millis when pos was sampled. Absent
    // (0) on paused/legacy states — then hold pos frozen.
    posAnchorMs: numOr(pick("posAnchorMs", "PosAnchorMs"), 0),
    // mediaAgeMs: ms since the phone reported (snapshot/summary only,
    // -1 = unknown). Used for the client's own staleness rule.
    mediaAgeMs: pick("mediaAgeMs", "MediaAgeMs") === undefined ? -1 : numOr(pick("mediaAgeMs", "MediaAgeMs"), -1),
    length: numOr(pick("length", "Length"), 0),
    volume: numOr(pick("volume", "Volume"), -1),
    deviceId: String(pick("deviceId", "DeviceId") || "")
  }
}

function numOr(value, fallback) {
  var n = Number(value)
  return isFinite(n) && n >= 0 ? n : fallback
}

// Parse `kcd mpris status --json` stdout. Empty array / garbage → null
// (panel shows "No media playing" rather than stale data).
function parseMprisStatus(text) {
  var raw = String(text || "").trim()
  if (raw === "" || raw === "null" || raw === "[]") return null
  var parsed = null
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return null
  }
  var list = parsed instanceof Array ? parsed : [parsed]
  for (var i = 0; i < list.length; i++) {
    var track = normalizeTrack(list[i])
    if (track !== null) return track
  }
  return null
}

// Album art is only loadable once the daemon has resolved it to a
// file:// or http(s):// URL. A raw `kdeconnect:/artUri?...` URI (fetch
// still in flight or failed) must render a placeholder instead.
function isUsableArt(url) {
  var u = String(url || "")
  return u.indexOf("file://") === 0 || u.indexOf("http://") === 0 || u.indexOf("https://") === 0
}

// Parse one `kcd watch --json` stdout line.
// Returns { skip: true } for the leading {"ok":true} ack and blank lines,
// { event: {...} } for real events, { skip: true } for garbage.
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

// argv arrays for Quickshell.execDetached (no shell quoting needed).
function watchCommand(events) {
  var cmd = ["kcd", "watch", "--json"]
  if (events && events.length > 0) {
    cmd.push("--events", events.join(","))
  }
  return cmd
}

function tileCommand(tile, deviceId) {
  var id = String(deviceId || "")
  if (tile === "ping") return ["kcd", "ping", id]
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

// `kcd pair -y` listen mode: enables pairing mode on the daemon and
// auto-accepts the first incoming request, then exits on its own.
// Run managed (not detached) so the panel can show pairing state and
// cancel it; no device id — requests can come from any phone.
function pairCommand() {
  return ["kcd", "pair", "-y"]
}

// `kcd share <id> <path>`: single file only, directories rejected by the
// CLI. The argv contract kcd-share.sh fulfills (it invokes kcd directly);
// spelled out here next to every other command builder.
function shareCommand(deviceId, filePath) {
  var id = String(deviceId || "")
  var path = String(filePath || "")
  if (id === "" || path === "") return null
  return ["kcd", "share", id, path]
}

// Screenshot-to-phone flow: Panel closes first, then
// kcd-screenshot-share.sh captures (grim) and sends via `kcd share`.
// The script path is resolved by the QML caller (it knows $HOME);
// the [bash, script, id, name] shape is spelled out here next to every
// other command builder.
function screenshotShareCommand(scriptPath, deviceId, deviceName) {
  var script = String(scriptPath || "")
  var id = String(deviceId || "")
  var name = String(deviceName || "")
  if (script === "" || id === "" || name === "") return null
  return ["bash", script, id, name]
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

// Parse `kcd battery --json <id>` output, e.g.
// '{"charge":69,"charging":false,"deviceId":"..."}', falling back to the
// legacy human format "Battery: 43% (charging)" for older binaries.
// Returns { charge, charging } or null.
function parseBatteryOutput(text) {
  var raw = String(text || "").trim()
  if (raw.charAt(0) === "{") {
    try {
      var parsed = JSON.parse(raw)
      var quick = normalizeBattery(parsed)
      if (quick) return quick
    } catch (e) {}
  }
  var m = raw.match(/(\d+)\s*%[^()]*\(([^)]+)\)/)
  if (!m) return null
  var state = String(m[2] || "")
  var charging = /charging/i.test(state) && !/discharging/i.test(state)
  return { charge: parseInt(m[1], 10), charging: charging }
}

// Sticky single-device framing: keep the previously selected device first
// while it is still present and usable (paired+connected), so two paired
// phones don't flap the auto-selection (and reset battery/track) on every
// refresh. A pinned device that lost pairing/connection stays in natural
// order so pickAutoDevice can move on.
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

// Parse `kcd --version` output, e.g.
// "kcd version v1.17.0 (commit 6bd0d7a, built 2026-09-12T07:13:42Z)".
// Returns "v1.17.0" or null.
function parseVersionOutput(text) {
  var m = String(text || "").match(/v\d+\.\d+\.\d+/)
  return m ? m[0] : null
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeDevice: normalizeDevice,
    parseDevicesOutput: parseDevicesOutput,
    normalizeDevices: normalizeDevices,
    normalizeBattery: normalizeBattery,
    normalizeSignal: normalizeSignal,
    formatLastSeen: formatLastSeen,
    isFreshMedia: isFreshMedia,
    isUsableDevice: isUsableDevice,
    pickPairedDevice: pickPairedDevice,
    pickAutoDevice: pickAutoDevice,
    normalizeTrack: normalizeTrack,
    parseMprisStatus: parseMprisStatus,
    parseBatteryOutput: parseBatteryOutput,
    parseVersionOutput: parseVersionOutput,
    configTomlPath: configTomlPath,
    pairCommand: pairCommand,
    shareCommand: shareCommand,
    screenshotShareCommand: screenshotShareCommand,
    stickDevice: stickDevice,
    isUsableArt: isUsableArt,
    parseWatchLine: parseWatchLine,
    watchCommand: watchCommand,
    tileCommand: tileCommand,
    mprisCommand: mprisCommand,
    batteryText: batteryText,
    batteryIcon: batteryIcon,
    batteryLevelIndex: batteryLevelIndex,
    positionText: positionText,
    progress: progress
  }
}
