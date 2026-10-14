# Narration — the one output path

Learned building pm's `core/verbose.rkt` (D-036). The rule: every
operation narrates itself completely and live — what, why, how, UTC
time, monotonic duration — to three destinations that are the SAME
record: screen line, JSON Lines log, AI feed file.

## The event schema (lift verbatim)

```
run-id, seq, parent-id, kind, depth,
who, what, why, how, inputs, outputs, result,
utc, mono-ms, duration-ms
```

- `kind` is closed: START STEP INFO DECIDE SKIP PROGRESS END FAIL WARN.
- `seq` is one counter per run, shared by nested operations (never
  restarted per level), so ordering survives nesting.
- `parent-id` points at the enclosing START event (`run#seq`).
- `utc` is wall time for humans; `duration-ms`/`mono-ms` come off the
  monotonic clock, never wall time, so clock changes can't skew them.

## Hard rules (all enforced in code, none by convention)

1. **`why` is mandatory** for step, decide, skip and failure. A blank
   reason raises instead of inventing a default. There are no silent
   skips: a SKIP without a reason is a bug in the caller.
2. **Nothing can switch it off.** No `--quiet`, no env var, no level
   that silences. (A prior `PM_TRACE=0` screen switch was explicitly
   superseded and removed.) Test harnesses may redirect the screen
   port; the feed file is never silenced.
3. **One redaction path, before every destination.** Secrets are
   scrubbed once, upstream of screen/log/feed, so no destination can
   leak what another redacts. Test it with a password-bearing URL and
   assert the secret appears nowhere.
4. **The writer never waits for a reader.** The feed is a file;
   `current` points at the active run id (written then atomically
   renamed). No listener changes nothing; a slow listener blocks nothing.
5. **Flush per event.** A killed process leaves a readable prefix, not
   a torn record. Partial (newline-unterminated) lines are left for the
   next write; truncated files restart the reader's cursor.

## Screen line shape

`[HH:MM:SSZ +0.250s] KIND who | what: ... | why: ... | how: ...`,
indented two spaces per depth. Durations vary, so golden tests assert
shape (kinds, order, indentation), never timestamps.

## What we got wrong first

- Per-level sequence counters (restart at zero per nesting): broke
  global ordering. One counter per run.
- Silencing via environment: one forgotten variable away from a dark
  cockpit. Removed the switch instead of guarding it.
- Redacting per destination: three routes, three chances to leak.
  Single path or nothing.
