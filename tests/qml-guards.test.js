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
