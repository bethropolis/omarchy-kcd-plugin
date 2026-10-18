// Structural guards for the QML sources: bindings clobbered by assignment
// fail only at runtime, so assert them here. Run: bun test tests/
import { describe, it, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const qml = (name) => readFileSync(join(root, name), "utf8");

describe("KcdIo Process bindings", () => {
  const src = qml("KcdIo.qml");

  // A `running: false` literal is panel-owned by design; assigning to a
  // bound one strips the binding permanently.
  const bound = [...src.matchAll(/property Process (\w+): Process \{\s*\n\s*running:\s*([^\n]*)/g)]
    .map((m) => ({ name: m[1], binding: m[2].trim() }))
    .filter((p) => /\bio\./.test(p.binding) || /&&|\|\|/.test(p.binding));

  it("treats the watch stream as the only bound Process", () => {
    // Must match something: an empty match guards nothing.
    expect(bound.map((b) => b.name)).toEqual(["watchProc"]);
    expect(bound[0].binding).toMatch(/io\.watchAlive/);
  });

  it("never assigns to a bound `running` property", () => {
    const offenders = bound
      .filter(({ name }) => new RegExp(`\\b${name}\\.running\\s*=`).test(src))
      .map(({ name }) => name);
    expect(offenders).toEqual([]);
  });

  it("keeps the death path idempotent so backoff arms once per dead stream", () => {
    // Without the latch the backoff would double twice per outage.
    expect(src).toMatch(/property bool watchDead/);
    expect(src).toMatch(/if \(io\.watchDead\) return/);
    // And the latch must be cleared when a stream actually starts.
    expect(src).toMatch(/if \(running\) \{\s*\n\s*io\.watchDead = false/);
  });
});

describe("media card null-safety", () => {
  const src = qml("MediaCard.qml");

  it("never dereferences track on hasTrack alone", () => {
    // hasTrack and track can disagree for an instant ("Value is null");
    // every dereference checks both.
    const derefs = [...src.matchAll(/card\.hasTrack \? (card\.track[^\n:]*)/g)].map((m) => m[0]);
    expect(derefs).toEqual([]);
  });

  it("loads artwork only through the gated artUrl()", () => {
    // artUrl() requires usableArt; any direct track-URL assignment would
    // bypass that gate.
    const loads = [...src.matchAll(/artwork\.source = ([\w.]*\(\)|"")/g)].map((m) => m[1]);
    expect(loads).toEqual(["artUrl()", "\"\"", "card.artUrl()"]);
  });
});
describe("pairing never auto-accepts", () => {
  const src = qml("KcdIo.qml");

  it("does not spawn `kcd pair -y` or `--yes` anywhere", () => {
    // Auto-accept trusts the first asker on the LAN before the owner sees
    // a code.
    expect(src).not.toMatch(/pair["',\s]+-y/);
    expect(src).not.toMatch(/--yes/);
    expect(src).toMatch(/--advertise-only/);
  });

  it("routes every pair.requested through the owner-decision handler", () => {
    expect(src).toMatch(/type === "pair\.requested"\) \{\s*\n\s*io\.handlePairRequested\(/);
    expect(src).toMatch(/function handlePairRequested/);
    expect(src).toMatch(/function acceptPendingPair/);
    expect(src).toMatch(/function rejectPendingPair/);
  });
});

describe("pairing panel states", () => {
  const unpaired = qml("KcdUnpaired.qml");
  const panel = qml("Panel.qml");
  const io = qml("KcdIo.qml");

  it("contains no auto-accept language anywhere near pairing", () => {
    expect(unpaired).not.toMatch(/pair -y/);
    expect(unpaired).not.toMatch(/auto-accept/i);
  });

  it("keys the decision UI off the pending request, not the code", () => {
    expect(unpaired).toMatch(/property string pendingPairId/);
    expect(unpaired).toMatch(/hasPending: root\.pendingPairId !== ""/);
    // No decision element may gate on verificationKey alone.
    const gated = [...unpaired.matchAll(/visible: root\.verificationKey !== ""/g)];
    expect(gated).toEqual([]);
  });

  it("headlines the request instead of claiming nothing is paired", () => {
    expect(unpaired).toMatch(/"Phone wants to pair"/);
    expect(unpaired).toMatch(/"Waiting for your phone"/);
  });

  it("offers an explicit Stop in both advertising states", () => {
    expect(unpaired).toMatch(/"Stop"/);
    expect(unpaired).toMatch(/"Stop pairing"/);
    // While deciding, the Start/Retry row hides and only Stop remains.
    expect(unpaired).toMatch(/visible: !root\.hasPending/);
  });

  it("plumbs pendingPairId from io through the panel", () => {
    expect(panel).toMatch(/pendingPairId: io\.pendingPairId/);
    expect(panel).toMatch(/pendingPairId: root\.pendingPairId/);
  });

  it("clears pending state on rejection, not just the code", () => {
    expect(io).toMatch(/type === "pair\.rejected"\) \{\s*\n\s*io\.clearPendingPair\(\)/);
  });
});

describe("deliberate bounces never flash the down page", () => {
  const src = qml("KcdIo.qml");
  const body = src.slice(src.indexOf("function noteWatchFailure()"));

  it("restarts a requested bounce before touching daemon state", () => {
    const bounce = body.indexOf("io.watchRestartRequested");
    const down = body.indexOf("io.daemonUp = false");
    expect(bounce).toBeGreaterThan(-1);
    expect(down).toBeGreaterThan(-1);
    expect(bounce).toBeLessThan(down);
    expect(body.slice(bounce, down)).toMatch(/return/);
  });
});

describe("downProbeTimer never runs when closed", () => {
  const src = qml("KcdIo.qml");
  const m = src.match(/property Timer downProbeTimer: Timer \{([\s\S]*?)\n  \}/);

  it("exists with a panelOpen-first running binding", () => {
    expect(m).not.toBeNull();
    // panelOpen first: closed stops the timer by binding.
    expect(m[1]).toMatch(/running: io\.panelOpen &&/);
  });

  it("fires only in the missing/down states", () => {
    expect(m[1]).toMatch(/uiState === "missing"/);
    expect(m[1]).toMatch(/uiState === "down"/);
    expect(m[1]).toMatch(/repeat: true/);
    expect(m[1]).toMatch(/io\.refresh\(\)/);
  });
});

describe("drag-to-seek", () => {
  const card = qml("MediaCard.qml");
  const io = qml("KcdIo.qml");
  const panel = qml("Panel.qml");

  it("commits the seek only on release, preview while held", () => {
    expect(card).toMatch(/signal mediaSeek\(double posMs\)/);
    expect(card).toMatch(/property double seekPreviewMs: -1/);
    // Release commits exactly once; cancel drops the preview silently.
    expect(card).toMatch(/onReleased: function\(\) \{ card\.finishSeek\(\) \}/);
    expect(card).toMatch(/card\.mediaSeek\(target\)/);
  });

  it("never seeks without a connection and a known length", () => {
    expect(card).toMatch(/enabled: card\.liveConnected && card\.canSeek && card\.trackLength > 0/);
    expect(card).toMatch(/if \(!card\.liveConnected \|\| !card\.canSeek \|\| !\(card\.trackLength > 0\)\) return/);
    expect(io).toMatch(/if \(!io\.liveConnected \|\| io\.deviceId === ""\) return/);
  });

  it("never rewinds the anchor with a stale clock", () => {
    // clockMs starts at 0; unfloored elapsed would rewind fresh drags.
    expect(io).toMatch(/base \+= Math\.max\(0, now - Number\(io\.liveTrack\.posAnchorMs\)\)/);
    expect(io).toMatch(/onPanelOpenChanged:[\s\S]*?io\.clockMs = Date\.now\(\)/);
  });

  it("holds the target until the daemon reports back", () => {
    expect(io).toMatch(/property double seekHoldMs: -1/);
    expect(io).toMatch(/var target = Math\.max\(0, Number\(positionMs\) \|\| 0\)/);
    expect(io).toMatch(/Kcd\.seekCommand\(io\.deviceId, target - io\.posAt\(Date\.now\(\)\)\)/);
    expect(io).toMatch(/io\.seekHoldMs = target/);
  });

  it("plumbs mediaSeek from card through panel to io", () => {
    expect(panel).toMatch(/function mediaSeek\(ms\) \{ io\.mediaSeek\(ms\) \}/);
    expect(panel).toMatch(/onMediaSeek: function\(ms\) \{ root\.mediaSeek\(ms\) \}/);
    expect(io).toMatch(/function mediaSeek\(positionMs\)/);
  });
});

describe("seek respects canSeek", () => {
  const card = qml("MediaCard.qml");
  const io = qml("KcdIo.qml");
  const panel = qml("Panel.qml");

  it("disables the drag when the player denies seeking", () => {
    expect(card).toMatch(/property bool canSeek: true/);
    expect(card).toMatch(/enabled: card\.liveConnected && card\.canSeek && card\.trackLength > 0/);
  });

  it("refuses to spawn a seek the player denied", () => {
    expect(io).toMatch(/io\.liveTrack\.canSeek === false\) return/);
  });

  it("plumbs canSeek null-safely from the track", () => {
    expect(panel).toMatch(/canSeek: root\.track \? root\.track\.canSeek !== false : true/);
  });
});

describe("icon font selection", () => {
  const io = qml("KcdIo.qml");
  const panel = qml("Panel.qml");
  const tile = qml("QuickTile.qml");
  const card = qml("MediaCard.qml");
  const bar = qml("BarWidget.qml");

  it("probes once and derives the icon family from the theme font", () => {
    expect(io).toMatch(/property Process fontProbeProc: Process/);
    expect(io).toMatch(/onStreamFinished: io\.probedIconFont = Kcd\.parseIconProbeOutput\(text\)/);
    expect(io).toMatch(/readonly property string iconFontFamily: Kcd\.iconFont\(io\.probedIconFont, io\.themeFontFamily\)/);
    // Both triggers needed: the injected value can equal the default.
    expect(io).toMatch(/onThemeFontFamilyChanged: io\.startFontProbe\(\)/);
    expect(io).toMatch(/Component\.onCompleted: io\.startFontProbe\(\)/);
    expect(io).toMatch(/fontProbeProc\.command = Kcd\.iconProbeCommand\(io\.themeFontFamily\)/);
  });

  it("hands the theme family down and the probed family back up", () => {
    expect(panel).toMatch(/themeFontFamily: root\.contentFontFamily/);
    expect(panel).toMatch(/readonly property string contentIconFont: io\.iconFontFamily/);
  });

  it("passes the probed family to every icon-bearing section", () => {
    const plumbed = [...panel.matchAll(/iconFontFamily: root\.contentIconFont/g)];
    // One per section; a new section without it drops to theme font.
    expect(plumbed.length).toBe(5);
  });

  it("keeps labels on the theme font and icons on the probed one", () => {
    expect(tile).toMatch(/property string iconFontFamily: fontFamily/);
    expect(tile).toMatch(/font\.family: root\.iconFontFamily/);
    // The tile label must keep the theme font.
    expect(tile).toMatch(/text: root\.label[\s\S]*?font\.family: root\.fontFamily/);
    expect(card).toMatch(/property string iconFontFamily: fontFamily/);
    expect(card).toMatch(/font\.family: card\.iconFontFamily/);
    // Transport buttons take the icon family; the title/artist do not.
    expect(card).toMatch(/fontFamily: card\.iconFontFamily/);
    expect(card).toMatch(/text: card\.hasTrack && card\.track \? card\.track\.title[\s\S]*?font\.family: card\.fontFamily/);
  });

  it("routes tile icons through the probed family in every host", () => {
    for (const [name, owner] of [
      ["QuickActionsRow.qml", "actions"],
      ["KcdMissing.qml", "root"],
      ["KcdUnpaired.qml", "root"],
    ]) {
      const src = qml(name);
      expect(src).toMatch(/property string iconFontFamily: fontFamily/);
      expect(src).toMatch(new RegExp(`iconFontFamily: ${owner}\\.iconFontFamily`));
    }
  });

  it("splits the closed-bar label into icon and figure runs", () => {
    expect(bar).toMatch(/readonly property string panelIconFont: panelLoader\.item \? String\(panelLoader\.item\.contentIconFont/);
    expect(bar).toMatch(/readonly property string barFontFamily: root\.bar \? root\.bar\.fontFamily : Style\.font\.family/);
    expect(bar).toMatch(/readonly property string barIconFont: root\.panelIconFont !== "" \? root\.panelIconFont : root\.barFontFamily/);
    // One Text, one family: the built-in label hides while `text` sizes.
    expect(bar).toMatch(/labelVisible: false/);
    expect(bar).toMatch(/text: root\.labelIcon/);
    expect(bar).toMatch(/font\.family: root\.barIconFont/);
    expect(bar).toMatch(/text: root\.labelFigures/);
    expect(bar).toMatch(/font\.family: root\.barFontFamily/);
  });
});

describe("volume wheel", () => {
  const card = qml("MediaCard.qml");
  const io = qml("KcdIo.qml");
  const panel = qml("Panel.qml");

  it("steps volume on wheel without stealing clicks", () => {
    expect(card).toMatch(/signal volumeAdjust\(int delta\)/);
    expect(card).toMatch(/acceptedButtons: Qt\.NoButton/);
    expect(card).toMatch(/Kcd\.stepVolume\(card\.track\.volume, steps \* 5\)/);
    expect(card).toMatch(/card\.volumeAdjust\(steps \* 5\)/);
  });

  it("swaps the badge to the level briefly, shifting no layout", () => {
    expect(card).toMatch(/property int volPreview: -1/);
    expect(card).toMatch(/"vol " \+ card\.volPreview \+ "%"/);
    expect(card).toMatch(/property Timer volTimer: Timer \{[\s\S]*?repeat: false/);
    expect(card).toMatch(/card\.volPreview = -1/);
  });

  it("plumbs volumeAdjust from card through panel to io", () => {
    expect(panel).toMatch(/function adjustVolume\(delta\) \{ io\.adjustVolume\(delta\) \}/);
    expect(panel).toMatch(/onVolumeAdjust: function\(delta\) \{ root\.adjustVolume\(delta\) \}/);
    expect(io).toMatch(/function adjustVolume\(delta\)/);
    expect(io).toMatch(/Kcd\.volumeCommand\(io\.deviceId, Kcd\.stepVolume\(io\.liveTrack\.volume, delta\)\)/);
  });
});
