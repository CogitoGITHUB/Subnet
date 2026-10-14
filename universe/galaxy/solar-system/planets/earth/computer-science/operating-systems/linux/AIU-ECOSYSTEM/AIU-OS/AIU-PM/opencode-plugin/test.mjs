// Offline test for the plugin's parsing and formatting. No pm, no
// OpenCode runtime, no network: synthetic JSON Lines exactly as
// core/verbose.rkt writes them, fed through the real functions.
//
//   node opencode-plugin/test.mjs

import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  drainFeed,
  currentRunId,
  listRunIds,
  formatEvent,
  summarizeRun,
  tailEvents,
} from "./aiu-pm.js";

// --- the fixtures ---------------------------------------------------------
// Byte-for-byte the shape core/verbose.rkt emits (see its tests).
const ev = (o) =>
  JSON.stringify({
    runId: "test-42",
    seq: 0,
    parentId: false,
    kind: "START",
    depth: 0,
    who: "test",
    what: "run",
    why: "session start",
    how: false,
    inputs: [],
    outputs: [],
    result: "test-42",
    utc: "10:00:00Z",
    monoMs: 1000,
    durationMs: 0,
    ...o,
  });

const FEED = [
  ev({ seq: 0, kind: "START", who: "test", what: "run", why: "session start", result: "test-42" }),
  ev({ seq: 1, kind: "START", who: "fetch", what: "pkg-alpha", why: "to install it", inputs: ["pkg-alpha"], parentId: "test-42#0" }),
  ev({ seq: 2, kind: "STEP", who: "fetch", what: "download", why: "the tarball is not in the cache", depth: 1, parentId: "test-42#1", how: "curl -sSfL" }),
  ev({ seq: 3, kind: "SKIP", who: "build", what: "configure", why: "no configure step in the spec", depth: 1, parentId: "test-42#1" }),
  ev({ seq: 4, kind: "DECIDE", who: "resolve", what: "source", why: "the spec pins a commit", depth: 1, parentId: "test-42#1", how: "chose git+commit over tarball" }),
  ev({ seq: 5, kind: "PROGRESS", who: "fetch", what: "bytes", why: "progress", depth: 1, parentId: "test-42#1", result: 9 }),
  ev({ seq: 6, kind: "FAIL", who: "build", what: "make", why: "the makefile failed", depth: 1, parentId: "test-42#1", result: "exit:2" }),
  ev({ seq: 7, kind: "END", who: "fetch", what: "pkg-alpha", why: "to install it", depth: 0, parentId: false, result: "failed" }),
  ev({ seq: 8, kind: "END", who: "run", what: "run", why: "session end", depth: 0, parentId: false, result: "done" }),
].join("\n") + "\n";

// --- formatting ------------------------------------------------------------

const parsed = FEED.trim().split("\n").map((l) => JSON.parse(l));

assert.equal(
  formatEvent(parsed[2]),
  "#2 STEP fetch: download (the tarball is not in the cache) [curl -sSfL]   "
);
assert.equal(
  formatEvent(parsed[3]),
  "#3 SKIP build: configure (no configure step in the spec)   "
);
assert.equal(
  formatEvent(parsed[0]),
  "#0 START test: run (session start)"
);

const s = summarizeRun(parsed);
assert.equal(s.count, 9);
assert.equal(s.runId, "test-42");
assert.equal(s.started, "run");
assert.equal(s.ended, true);
assert.equal(s.failures.length, 1);
assert.match(s.failures[0], /build: make -- exit:2/);
assert.match(s.summary, /9 events/);
assert.match(s.summary, /run closed/);
assert.match(s.summary, /1 failure/);

// A run that has not closed yet must not claim it closed.
const open = summarizeRun(parsed.slice(0, 3));
assert.equal(open.ended, false);
assert.match(open.summary, /run still open/);

assert.equal(summarizeRun([]).count, 0);

const t1 = tailEvents(parsed, 0, 3);
assert.equal(t1.count, 8);
assert.equal(t1.returned, 3);
assert.equal(t1.nextSeq, 8);
assert.ok(t1.lines[0].startsWith("#6"));

const t2 = tailEvents(parsed, 5);
assert.equal(t2.returned, 3);
assert.ok(t2.lines[0].startsWith("#6"));

assert.equal(tailEvents(parsed, 8).returned, 0);
assert.equal(tailEvents(parsed, 8).nextSeq, 8);

// --- the reader, against a real temp directory -----------------------------

const dir = mkdtempSync(join(tmpdir(), "pm-plugin-test-"));
try {
  writeFileSync(join(dir, "test-42.jsonl"), FEED);
  writeFileSync(join(dir, "current"), "test-42\n");

  assert.equal(currentRunId(dir), "test-42");
  assert.deepEqual(listRunIds(dir), ["test-42"]);

  const first = drainFeed(dir, "test-42");
  assert.equal(first.length, 9);
  assert.equal(first[0].kind, "START");

  // Draining again with no new bytes yields nothing: the cursor works.
  assert.equal(drainFeed(dir, "test-42").length, 0);

  // Appending is picked up, and only the new part is re-read.
  writeFileSync(
    join(dir, "test-42.jsonl"),
    FEED + ev({ seq: 9, kind: "END", who: "run", what: "run", why: "session end", depth: 0, result: "later" }) + "\n"
  );
  const second = drainFeed(dir, "test-42");
  assert.equal(second.length, 1);
  assert.equal(second[0].seq, 9);

  // A partial (not yet newline-terminated) line is NOT consumed: pm
  // flushes per event, but a reader can still catch a half write.
  writeFileSync(join(dir, "test-77.jsonl"), ev({ runId: "test-77", seq: 0 }) + "\n" + ev({ runId: "test-77", seq: 1 }).slice(0, 20));
  const partial = drainFeed(dir, "test-77");
  assert.equal(partial.length, 1);
  assert.equal(partial[0].seq, 0);

  // A truncated file restarts the cursor instead of reading garbage.
  writeFileSync(join(dir, "test-42.jsonl"), ev({ seq: 0 }) + "\n");
  const after = drainFeed(dir, "test-42");
  assert.equal(after.length, 1);
  assert.equal(after[0].seq, 0);

  // No feed file at all is not an error.
  assert.equal(drainFeed(dir, "no-such-run").length, 0);
  assert.equal(currentRunId(join(dir, "nope")), null);
  assert.deepEqual(listRunIds(join(dir, "nope")), []);
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log("opencode-plugin: all assertions passed");