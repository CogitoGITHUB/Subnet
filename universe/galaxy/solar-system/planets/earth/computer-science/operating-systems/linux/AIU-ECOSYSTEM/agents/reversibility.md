# Reversibility — journaled stepwise work

Learned building pm's apply/journal/store trio. The rule: any
multi-step mutation is journaled by content hash as it goes, so a
killed run resumes instead of restarting, and a repeated run is a
proven no-op.

## The pattern

- **Steps are named deterministically**: `step-<index>-<kind>`, derived
  from the plan itself. Same plan twice → same step names. This is what
  makes resume possible at all.
- **Journal lines are (step, input-hash, event)** with `start`/`end`
  records, append-only, one file per unit of work. A step is done iff
  its `end` record exists under the CURRENT input hash.
- **Input hash changes rerun everything.** Content addressing is the
  whole invalidation strategy; there is no separate "dirty" flag to
  rot.
- **Re-running is the test**: apply the same plan twice and assert the
  performer ran zero times the second time, with every step reporting
  SKIP naming the matched hash.
- **Cancel lands between steps, never mid-step.** Cancellation is an
  interrupted run and resumes like one. No timers: the cancel source
  is an event the loop already waits on.
- **Markers for crash consistency**: a `.pm-incomplete`-style marker
  names the in-progress run; success clears it. A failed run leaves
  the previous good state untouched (fail closed) — assert the old
  link target still resolves after a deliberately failed apply.

## The partial-failure law (state it per project)

Write down, per operation, which of these holds — never leave it implied:

- **RESUME** (apply): journal names completed steps; rerun skips them.
- **ATOMIC** (pointer flips): build beside, swap once; a kill leaves
  either the old or the new whole state, never half.
- **RETRY** (fetches): per-unit failure, retried alone, never poisoning
  siblings.

Then test the feed of an interrupted run: it must show FAIL plus the
resume SKIPs, so a reader knows which law applied.

## Locking

One writer, try-lock, fail fast naming the holder. Readers never lock.
A second concurrent mutation is refused immediately — never queued
silently, never interleaved. Test the refusal with a held lock.

## What we got wrong first

- Clearing scratch dirs at run start: broke both the fetch/update
  decision (clone vs update needs the dir's current shape) and resume
  (a completed export's tree got deleted, then later steps starved).
  Create-if-missing, clear only what the journal proves unfinished.
- One dir for two jobs (fetch mirror + export tree): each needs its
  own directory with its own lifecycle. Name them separately.
- Pre-creating outputs "for convenience": every pre-created path is a
  decision about state. Let the performing step own its outputs.
