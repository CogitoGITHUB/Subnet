# CyberDeck agent rules

Applies to any session working in `CyberDeck/`. These exist because each
one was learned by getting it wrong first.

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

`backends/jobs.rkt` is red: 17 tests pass, then `control: arity mismatch`
with no srcloc. Do not paper over it with a tier exemption — fix it or
report it. The fast/slow tier split in `check.nu` was a workaround and is
being removed; every `.rkt` gets tested.