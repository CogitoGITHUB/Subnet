# CyberDeck agent rules

Applies to any session working in `CyberDeck/`. These exist because each
one was learned by getting it wrong first.

## Use the built-in file tools. Never edit files with shell scripts.

| to do this | use this | never this |
|------------|----------|------------|
| look at a file | `read` (gives line numbers) | `cat`, `sed -n` |
| change a file | `edit` (exact match, fails if 0 or >1) | python/sed/heredoc |
| create a file | `write` | shell redirection |
| check it parses | `scripts/read-check.rkt` | a one-off paren one-liner |

The built-in `edit` tool refuses to run when the old text is missing or
ambiguous. That refusal is the whole point: it makes silent corruption
impossible. Every mangled file in this project came from bypassing it
with a python heredoc — `[root]` became `(root)`, a closing paren was
dropped twice, a shebang and `#lang` got reordered. None of those could
have happened through `edit`.

## How to move fast (this is what worked, 2026-10-10)

1. **Read the source before theorising.** Every guess about a Racket API
   cost a 40-second test run to disprove. Reading
   `collects/racket/system.rkt` gave the `subprocess` signature in one
   second.
2. **Use the built-in `read` and `edit`.** `read` shows line numbers and
   `edit` fails loudly on a bad match. Never `python3 <<EOF`, `sed -i`,
   or heredocs for file changes.
3. **Reproduce in `/tmp` before touching the repo.** A standalone replica
   of one test's choreography runs in ~2s instead of 40s, so the loop
   stops costing minutes.
4. **Let the error name the mistake.** Racket's contract errors were
   exact every time. Read the whole error: `expected: at least 4,
   given: 3` is what revealed that `subprocess` takes three stream
   redirections before the exe.
5. **Instrument the child, not the parent.** Markers written to a
   captured stderr file show exactly how far a spawned process got,
   instead of inferring it.
6. **Kill orphans first.** One stale process holding a lock makes every
   later run hang, and the symptom looks like a fresh bug each time.
   Check with `ps -eo args | grep <fixture-prefix>` before starting.

## What cost the most time, so it is not repeated

- Guessing at an API instead of reading its definition.
- Editing through a shell script, which silently corrupted three files.
- Chasing a hang whose real cause was 16 leftover processes holding a
  lock, while the code under test was fine.
- Assuming `jobs.rkt` had a handshake bug when the handshake was correct
  and a stale lock holder was the actual blocker.

## ## Always use the shared runner, and read its timer lines

`scripts/test-runner.rkt` prints progress and elapsed time EVERY run:

```
TEST-START <file> at=<ms since run start> of=<n files>
TEST-END   <file> failed=<n> total=<n> ms=<n> at=<ms>
SUSPECT:   <file> <ms>          <- over 2000ms, information only
SUMMARY files=<n> failed=<n> total=<n>
```

- **A `TEST-START` with no matching `TEST-END` is a stuck file**, and
  `at=` says how long it has been stuck. Do not sit on silence: read the
  log, then look at the process.
- `SUSPECT:` marks slow files. Slow is information, never a reason to
  skip a file or give it its own process.
- No timers in this behaviour: nothing waits on a clock, nothing is
  killed automatically, `SUSPECT` is a report not a limit (D-015).

## No fast/slow tiers

Every `.rkt` is tested, always, in ONE shared process. A file that hangs
or fails there is an ERROR to isolate and fix (dynamic-wind, temp dirs,
parameterize cwd/env, kill and reap children), never a reason to give it
a separate tier. Measured proof spawners are fine in the shared process:
`backends/git.rkt` (54 tests), `backends/local.rkt` (15) and
`backends/run.rkt` (52) all pass there.

## Scripts in `scripts/` exist to RUN things, not to change text.

## Commit and push constantly

Never leave work uncommitted. After every change:

1. `scripts/read-check.rkt <the file>`
2. `git add` the explicit paths, `git commit`
3. `git push`

**Never** use `git checkout -- <file>` to undo an edit. It discards
every uncommitted change in that file, not just the one you meant to
revert; it destroyed a green working tree twice. `git stash` puts work
aside without destroying it. If a file is broken, save it with
`git diff HEAD -- <file> > docs/patches/<name>.patch` and then restore
the committed version.

## Use the scripts that exist. Do not improvise equivalents.

| need | command |
|------|---------|
| check parens / parse | `~/opt/racket/bin/racket scripts/read-check.rkt <files...>` |
| interactive Racket | `~/opt/racket/bin/racket scripts/repl.rkt` |
| quick test of fast-tier files | `~/opt/racket/bin/racket scripts/test-runner.rkt <files...>` |
| the gate | `~/opt/nushell/0.116.1/nu --no-config-file scripts/check.nu --fast` |
| between items | `... scripts/check.nu --changed` |
| full gate, end of phase | `... scripts/check.nu` |

**Never** write a python heredoc to patch a `.rkt`, and never re-derive a
paren check by hand. `scripts/read-check.rkt` is the paren check. If it
does not cover the case you need, fix or extend it, then use it.

## When a script cannot do the job, build it, then use it

If a task needs the same mechanics three times, that is a missing script,
not a repeated command. Add it under `scripts/`, make it take arguments
rather than hard-coded paths, and run it from then on. New scripts get a
row in `docs/RACKET-TOOLING.org`.

## Ground rules

- **No timers.** No `timeout`, `sleep`, polling loop, or foreground wait,
  in the project **or in shell commands**. Long runs are launched as the
  tracked background command itself — no `nohup ... &`, which detaches
  the run from its task and loses the exit code. Wait on process exit.
- **Synthetic fixtures only** in tests (T-10). Real package names and pins
  appear only in docs, pasted from real output.
- **One commit per unit, explicit paths.** Save uncommitted work to
  `docs/patches/` before any `git checkout`; a checkout once destroyed a
  green working tree.
- **Never claim "verified" without pasting the output.**
- Racket is 9.3 CS **minimal**. `racket/glob`, `racket/environment` and
  `directory-list-recursively` do not exist. `json` IS bundled.
  `read-line-evt` modes are exactly
  `'(linefeed return return-linefeed any any-one)` — `'line` does not
  exist. The parameter is `exit-handler`, not `current-exit-handler`.
  See `docs/RACKET-TOOLING.org`.

## Before editing any `.rkt`

1. `racket scripts/read-check.rkt <the file>` — green before the edit.
2. Make the edit.
3. `racket scripts/read-check.rkt <the file>` — green after the edit, with
   a `file:line` if not.
4. Test with `scripts/test-runner.rkt` for fast-tier files, `raco test`
   for the rest.

## Startup cost, measured

`racket -n -e ''` varies 0.29s to 1.12s for the same empty program on this
phone. That spread is filesystem variance under proot, not compute. Every
separate process pays it, which is exactly why `scripts/test-runner.rkt`
runs files in one shared process. Prefer one process doing many things
over many processes doing one thing.

## Current state

`backends/jobs.rkt` is red and the handshake is NOT the bug. Established
with output: the O_RDWR open, `'linefeed` mode and `read-line-evt` are
correct; `subprocess-wait` returns immediately in this Racket even while
the child runs, so a reaper thread plus semaphore cannot be trusted to
signal death. The design that removes the dependency is to CLOSE the
parent's own write end of the fifo right after opening it, so the holder
is the only writer and its death shows up as EOF on the read end. A
holder that writes `"up"` and then blocks on a fifo is the real shape;
there are no timers in it. Verify this in a `/tmp` replica first.

`scripts/check.nu` tier removal is saved at
`docs/patches/WIP-checknu-tiers-removed.patch`, not applied.