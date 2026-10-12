// Structural guards for the QML sources.
//
// These cannot be unit tested through Kcd.js, but they can be asserted: a
// binding that gets clobbered by an assignment is a runtime-only failure that
// no amount of bun testing would catch. It bit us once -- watchStreamGuard
// assigned `watchProc.running`, which stripped the `running: installOk &&
// watchAlive` binding, so after a single guard trip the backoff restart could
// never bring the stream back and the panel sat on "daemon isn't running"
// while the daemon was perfectly healthy.
//
// Run: bun test tests/
import { describe, it, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const qml = (name) => readFileSync(join(root, name), "utf8");

describe("KcdIo Process bindings", () => {
  const src = qml("KcdIo.qml");

  // Process blocks whose `running:` is driven by other properties. A literal
  // `running: false` is only an initial value that the panel controls by
  // assignment, which is the intended design for one-shot probes; assigning to
  // a *bound* one strips the binding permanently, so nothing can turn that
  // process back on.
  const bound = [...src.matchAll(/property Process (\w+): Process \{\s*\n\s*running:\s*([^\n]*)/g)]
    .map((m) => ({ name: m[1], binding: m[2].trim() }))
    .filter((p) => /\bio\./.test(p.binding) || /&&|\|\|/.test(p.binding));

  it("treats the watch stream as the only bound Process", () => {
    // Guard against this test silently matching nothing if the file is
    // reformatted.
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
    // Dropping the stream fires onExited too, so without the watchDead latch
    // the backoff would double twice per outage.
    expect(src).toMatch(/property bool watchDead/);
    expect(src).toMatch(/if \(io\.watchDead\) return/);
    // And the latch must be cleared when a stream actually starts.
    expect(src).toMatch(/if \(running\) \{\s*\n\s*io\.watchDead = false/);
  });
});

describe("media card null-safety", () => {
  const src = qml("MediaCard.qml");

  it("never dereferences track on hasTrack alone", () => {
    // hasTrack and track are separate bindings and can disagree for an
    // instant, which produced "Value is null" TypeErrors on every media
    // repaint. Every dereference must also check track itself.
    const derefs = [...src.matchAll(/card\.hasTrack \? (card\.track[^\n:]*)/g)].map((m) => m[0]);
    expect(derefs).toEqual([]);
  });
});
describe("pairing never auto-accepts", () => {
  const src = qml("KcdIo.qml");

  it("does not spawn `kcd pair -y` or `--yes` anywhere", () => {
    // The marketplace security review flagged this exact shape: the first
    // device to ask on the LAN becomes trusted before the owner ever sees
    // a code. Advertising plus a per-device accept is the replacement.
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
    // A key-less request must still be decidable: no decision element
    // may gate on verificationKey alone.
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
    // panelOpen must be the first conjunct: closed stops the timer by
    // binding, regardless of what follows.
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
    // clockMs is 0 until the first tick after opening: elapsed must floor
    // at 0 or a fresh drag computes from position 0 and overshoots.
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
