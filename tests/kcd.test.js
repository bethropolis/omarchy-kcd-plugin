// Unit tests for ../Kcd.js (pure helpers, no Qt).
// Run: bun test tests/
import { describe, it, expect } from "bun:test";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const Kcd = require("../Kcd.js");

describe("normalizeDevice", () => {
  it("normalizes the lowercase IPC shape", () => {
    expect(
      Kcd.normalizeDevice({
        id: "abc", name: "Pixel", type: "phone",
        state: "PAIRED", connected: true,
      }),
    ).toEqual({
      id: "abc", name: "Pixel", type: "phone", state: "PAIRED",
      connected: true, battery: null, media: null, lastSeen: "", signal: null,
    });
  });

  it("normalizes the CAPITALIZED kcd --json shape", () => {
    const d = Kcd.normalizeDevice({
      ID: "abc", Name: "Pixel", Type: "phone",
      State: "PAIRED", Connected: true,
    });
    expect(d.id).toBe("abc");
    expect(d.name).toBe("Pixel");
    expect(d.connected).toBe(true);
  });

  it("returns null without an id", () => {
    expect(Kcd.normalizeDevice(null)).toBeNull();
    expect(Kcd.normalizeDevice({})).toBeNull();
    expect(Kcd.normalizeDevice({ id: "" })).toBeNull();
  });

  it("falls back to id for name, phone for type, UNKNOWN for state", () => {
    const d = Kcd.normalizeDevice({ id: "abc" });
    expect(d.name).toBe("abc");
    expect(d.type).toBe("phone");
    expect(d.state).toBe("UNKNOWN");
    expect(d.connected).toBe(false);
  });

  it("isSafeDeviceId admits real ID shapes, rejects shell metacharacters", () => {
    expect(Kcd.isSafeDeviceId("9a5c23ea_7195_4da1_b766_282b7256a02d")).toBe(true);
    expect(Kcd.isSafeDeviceId("abc")).toBe(true);
    expect(Kcd.isSafeDeviceId("phone-1:2.3")).toBe(true);
    expect(Kcd.isSafeDeviceId("x'; rm -rf ~; echo '")).toBe(false);
    expect(Kcd.isSafeDeviceId("a;id")).toBe(false);
    expect(Kcd.isSafeDeviceId("$(id)")).toBe(false);
    expect(Kcd.isSafeDeviceId("`id`")).toBe(false);
    expect(Kcd.isSafeDeviceId("a b")).toBe(false);
    expect(Kcd.isSafeDeviceId("")).toBe(false);
    expect(Kcd.isSafeDeviceId(null)).toBe(false);
  });

  it("drops hostile-ID devices at intake", () => {
    expect(Kcd.normalizeDevice({ id: "x'; touch /tmp/pwned; echo '" })).toBeNull();
    expect(Kcd.normalizeDevices([
      { id: "abc", state: "PAIRED", connected: true },
      { id: "x'; touch /tmp/pwned; echo '", state: "PAIRED", connected: true },
    ]).map((d) => d.id)).toEqual(["abc"]);
  });
});

describe("parseDevicesOutput / normalizeDevices", () => {
  it("returns [] on empty or garbage", () => {
    expect(Kcd.parseDevicesOutput("")).toEqual([]);
    expect(Kcd.parseDevicesOutput("  ")).toEqual([]);
    expect(Kcd.parseDevicesOutput("not json")).toEqual([]);
  });

  it("wraps a single object into a list", () => {
    const out = Kcd.parseDevicesOutput('{"id":"a","state":"PAIRED"}');
    expect(out.length).toBe(1);
    expect(out[0].id).toBe("a");
  });

  it("drops entries without ids", () => {
    expect(Kcd.parseDevicesOutput('[{}, {"id":"a"}]').map((d) => d.id)).toEqual(["a"]);
  });

  it("normalizeDevices rejects non-arrays", () => {
    expect(Kcd.normalizeDevices(null)).toEqual([]);
    expect(Kcd.normalizeDevices({})).toEqual([]);
  });
});

describe("device selection", () => {
  const usable = { id: "u", state: "PAIRED", connected: true };
  const offline = { id: "o", state: "PAIRED", connected: false };
  const stranger = { id: "s", state: "UNPAIRED", connected: true };

  it("isUsableDevice needs paired + connected", () => {
    expect(Kcd.isUsableDevice(usable)).toBe(true);
    expect(Kcd.isUsableDevice(offline)).toBe(false);
    expect(Kcd.isUsableDevice(stranger)).toBe(false);
    expect(Kcd.isUsableDevice(null)).toBe(false);
    expect(Kcd.isUsableDevice({ id: "x", state: "paired", connected: true })).toBe(true);
  });

  it("pickAutoDevice skips strangers and offline phones", () => {
    expect(Kcd.pickAutoDevice([stranger, offline])).toBeNull();
    expect(Kcd.pickAutoDevice([stranger, usable])).toEqual(usable);
    expect(Kcd.pickAutoDevice([])).toBeNull();
  });

  it("pickPairedDevice finds offline-but-paired phones", () => {
    expect(Kcd.pickPairedDevice([stranger, offline])).toEqual(offline);
    expect(Kcd.pickPairedDevice([stranger])).toBeNull();
  });

  it("stickDevice keeps a usable pinned device first", () => {
    const a = { id: "a", state: "PAIRED", connected: true };
    const b = { id: "b", state: "PAIRED", connected: true };
    expect(Kcd.stickDevice([a, b], "b").map((d) => d.id)).toEqual(["b", "a"]);
    expect(Kcd.stickDevice([a, b], "zzz")).toEqual([a, b]);
    expect(Kcd.stickDevice([], "b")).toEqual([]);
  });
});

describe("normalizeBattery", () => {
  it("rounds charge and keeps charging strict", () => {
    expect(Kcd.normalizeBattery({ charge: 69.4, charging: true })).toEqual({ charge: 69, charging: true });
    expect(Kcd.normalizeBattery({ Charge: 43, Charging: 1 })).toEqual({ charge: 43, charging: false });
  });

  it("returns null when absent or invalid", () => {
    expect(Kcd.normalizeBattery(null)).toBeNull();
    expect(Kcd.normalizeBattery({})).toBeNull();
    expect(Kcd.normalizeBattery({ charge: -1 })).toBeNull();
  });
});

describe("parseBatteryOutput", () => {
  it("parses the --json object", () => {
    expect(Kcd.parseBatteryOutput('{"charge":69,"charging":false,"deviceId":"x"}')).toEqual({
      charge: 69, charging: false,
    });
  });

  it("parses the legacy human format", () => {
    expect(Kcd.parseBatteryOutput("Battery: 43% (charging)")).toEqual({ charge: 43, charging: true });
    expect(Kcd.parseBatteryOutput("Battery: 43% (discharging)")).toEqual({ charge: 43, charging: false });
  });

  it("returns null on garbage", () => {
    expect(Kcd.parseBatteryOutput("")).toBeNull();
    expect(Kcd.parseBatteryOutput("hello")).toBeNull();
  });
});

describe("media helpers", () => {
  const track = (over = {}) => ({
    player: "spotify", title: "Song", artist: "A", album: "B",
    isPlaying: true, pos: 1000, posAnchorMs: 5, length: 2000,
    ...over,
  });

  it("normalizeTrack needs a title", () => {
    expect(Kcd.normalizeTrack(null)).toBeNull();
    expect(Kcd.normalizeTrack({ player: "x" })).toBeNull();
    expect(Kcd.normalizeTrack(track()).title).toBe("Song");
    expect(Kcd.normalizeTrack({ Title: "T" }).title).toBe("T");
  });

  it("isFreshMedia trusts playing, gates stale paused", () => {
    expect(Kcd.isFreshMedia(track())).toBe(true);
    expect(Kcd.isFreshMedia(track({ isPlaying: false, mediaAgeMs: 5000 }))).toBe(true);
    expect(Kcd.isFreshMedia(track({ isPlaying: false, mediaAgeMs: 60000 }))).toBe(false);
    expect(Kcd.isFreshMedia(null)).toBe(false);
  });

  it("parseMprisStatus returns the first valid track or null", () => {
    expect(Kcd.parseMprisStatus("")).toBeNull();
    expect(Kcd.parseMprisStatus("[]")).toBeNull();
    expect(Kcd.parseMprisStatus("nope")).toBeNull();
    expect(Kcd.parseMprisStatus('[{"title":"T"}]').title).toBe("T");
  });

  it("isUsableArt only allows loadable urls", () => {
    expect(Kcd.isUsableArt("file:///a.jpg")).toBe(true);
    expect(Kcd.isUsableArt("https://x/y.png")).toBe(true);
    expect(Kcd.isUsableArt("kdeconnect:/artUri?x=1")).toBe(false);
    expect(Kcd.isUsableArt("")).toBe(false);
  });

  it("positionText and progress", () => {
    expect(Kcd.positionText(62000, 180000)).toBe("1:02 / 3:00");
    expect(Kcd.positionText(0, 0)).toBe("0:00");
    expect(Kcd.progress(30, 120)).toBe(0.25);
    expect(Kcd.progress(5, 0)).toBe(0);
  });
});

describe("parseWatchLine", () => {
  it("skips blanks, acks and garbage", () => {
    expect(Kcd.parseWatchLine("")).toEqual({ skip: true });
    expect(Kcd.parseWatchLine('{"ok":true}')).toEqual({ skip: true });
    expect(Kcd.parseWatchLine("{{{").skip).toBe(true);
  });

  it("returns typed events with defaults", () => {
    expect(Kcd.parseWatchLine('{"type":"battery.update","deviceId":"d","payload":{"charge":80}}')).toEqual({
      event: { type: "battery.update", deviceId: "d", timestamp: "", payload: { charge: 80 } },
    });
  });
});

describe("command builders", () => {
  it("tileCommand maps tiles and guards ping/ring", () => {
    expect(Kcd.tileCommand("ping", "d")).toEqual(["kcd", "ping", "d"]);
    expect(Kcd.tileCommand("ring", "d")).toEqual(["kcd", "findmyphone", "d"]);
    expect(Kcd.tileCommand("clipboard", "d")).toEqual(["kcd", "clipboard", "d"]);
    expect(Kcd.tileCommand("clipboard", "")).toEqual(["kcd", "clipboard"]);
    expect(Kcd.tileCommand("nope", "d")).toBeNull();
  });

  it("watchCommand joins event filters", () => {
    expect(Kcd.watchCommand()).toEqual(["kcd", "watch", "--json"]);
    expect(Kcd.watchCommand(["a", "b"])).toEqual(["kcd", "watch", "--json", "--events", "a,b"]);
  });

  it("mprisCommand and pairCommand", () => {
    expect(Kcd.mprisCommand("next", "d")).toEqual(["kcd", "mpris", "next", "--device", "d"]);
    expect(Kcd.mprisCommand("next", "")).toEqual(["kcd", "mpris", "next"]);
    expect(Kcd.pairCommand()).toEqual(["kcd", "pair", "-y"]);
  });

  it("shareCommand and screenshotShareCommand reject blanks", () => {
    expect(Kcd.shareCommand("d", "/f")).toEqual(["kcd", "share", "d", "/f"]);
    expect(Kcd.shareCommand("", "/f")).toBeNull();
    expect(Kcd.shareCommand("d", "")).toBeNull();
    expect(Kcd.screenshotShareCommand("/s", "d", "n")).toEqual(["bash", "/s", "d", "n"]);
    expect(Kcd.screenshotShareCommand("", "d", "n")).toBeNull();
    expect(Kcd.screenshotShareCommand("/s", "", "n")).toBeNull();
  });

  it("configTomlPath respects XDG then HOME", () => {
    expect(Kcd.configTomlPath("/h", "/x")).toBe("/x/kcd/kcd.toml");
    expect(Kcd.configTomlPath("/h", "")).toBe("/h/.config/kcd/kcd.toml");
    expect(Kcd.configTomlPath("", "")).toBe("~/.config/kcd/kcd.toml");
  });
});

describe("battery + misc display", () => {
  it("batteryText and icons", () => {
    expect(Kcd.batteryText(69, false)).toBe("69%");
    expect(Kcd.batteryText(-1, false)).toBe("--");
    expect(Kcd.batteryLevelIndex(95)).toBe(9);
    expect(Kcd.batteryLevelIndex(-1)).toBe(-1);
    expect(Kcd.batteryIcon(69, true)).not.toBe(Kcd.batteryIcon(69, false));
  });

  it("parseVersionOutput and formatLastSeen", () => {
    expect(Kcd.parseVersionOutput("kcd version v1.17.0 (commit x)")).toBe("v1.17.0");
    expect(Kcd.parseVersionOutput("kcd version 1.18.0 (commit 8126626e4c2c16787f7cfea68e51bae6af42f195, built 2026-09-15T23:05:40Z)")).toBe("v1.18.0");
    expect(Kcd.parseVersionOutput("nothing")).toBeNull();
    expect(Kcd.formatLastSeen("garbage")).toBe("—");
    expect(Kcd.formatLastSeen(new Date().toISOString())).toBe("Now");
  });

  it("normalizeSignal reduces to a label", () => {
    expect(Kcd.normalizeSignal({ signalStrengths: { "0": { networkDetailedType: "LTE" } } }).label).toBe("LTE");
    expect(Kcd.normalizeSignal({ signalStrengths: { "0": { networkType: "Unknown" } } })).toBeNull();
    expect(Kcd.normalizeSignal(null)).toBeNull();
  });
});
