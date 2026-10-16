# Naming — the rule and the reasons

Binding version: `HARD-RULES.org` section 3. This file is the working
detail and the evidence.

## The rule

**A name states the job the thing does.** Not the layer it sits in,
not the pattern it follows, not the decade it was written in.

| bad | good | why the bad one hurts |
|-----|------|---------------------|
| `core/plan.rkt` | `lower-build-steps-into-install-actions.rkt` | "plan" hides a compiler |
| `core/` | `spec-reading/`, `naming/`, `narration/` | describes a location, not a job |
| `run.rkt` | `spawn-process-and-read-its-exit-status.rkt` | "run" hides the status protocol |
| `utils.rkt` | `levenshtein-distance.rkt` | "utils" means "nobody decided" |
| `local.rkt` | `perform-action-on-this-machine.rkt` | "local" as opposed to what? |
| `plan(p)` | `resolve-deps-in-order(p)` | noun hides the verb |

## Why this is not bikeshedding

The owner of this ecosystem read a directory listing and could not tell
what any file did. That is the whole cost, and it is paid on every read
forever.

Concretely, in one afternoon the inventory found **seven files doing
five to seven unrelated jobs each**, behind names that promised one.
`backends/vault.rkt` was 1652 lines of six subsystems: git environment,
ref storage, vault creation, network transfer, integrity checks, and a
disk-capacity collision check. Nobody could have guessed that from the
name, and no one would have opened it.

## The banned list

`core` · `engine` · `main` · `utils` · `util` · `helpers` · `common` ·
`base` · `manager` · `service` · `handler` · `misc` · `stuff` · `data` ·
`types` · `config` · `things` · `stuff`

Each of these is banned because it names a **category** instead of a
**job**. `config.rkt` might mean "reads the config file" or "defines the
config schema" or "holds three unrelated settings" — the name cannot
distinguish those, so the reader must open the file. Every one of them
is a decision deferred to the reader, which is the thing we are trying
to stop doing.

`main` is a special case: an entry point may legitimately be called
`main`, but only if it does nothing but dispatch.

## One file, one job

The test: **could you delete this file and lose exactly one thing?**
If the honest answer is "two unrelated things", split it.

Real splits from the inventory:

- `backends/build.rkt` → `build-env.rkt` + `build-executor.rkt` +
  `build-systems/{make,cmake,cargo,configure,run}.rkt`
- `backends/jobs.rkt` → `job-record.rkt` + `job-queue.rkt` +
  `job-worker-locks.rkt`
- `core/spec-read.rkt` → `spec-typos.rkt` + `spec-fields.rkt` +
  `spec-source.rkt` + `spec-build-steps.rkt`
- `cli/main.rkt` → `cli/parse.rkt` + `cli/commands.rkt` +
  `cli/documents.rkt` + `cli/dispatch.rkt` + `cli/main-test.rkt`

Splitting costs an hour once. Not splitting costs every future read.

## Stages, gates and lints

Binding: `HARD-RULES.org` 3.7 and 3.8.

A stage name states what it checks. `text-lint`, `one-printer-lint`,
`security-gate-lint` — reading the gate output tells you what ran and
what a red means. `stage 6` tells you nothing without opening the
source, and it lies the moment the order changes.

Sub-stages read `parent-name/rule`: `text-lint/line-length`,
`security-gate-lint/audited-writers`. They select the same way on the
command line: `CYBERDECK_STAGES=text-lint/line-length`.

The runner is the reference. `nu gate/check.nu --list` prints every
stage name and what it checks, from the same table the dispatcher
validates against, so the list cannot drift from what runs. A wrong
or retired name fails loudly — exit 2 or a named reason — and never
runs nothing silently.

## Directories

Name a directory for the job its contents share. Do not create a
`core/` versus `backends/` split — that is pure/purely-impure, which
says nothing about what anything does. Prefer naming by job
(`narration/`, `naming/`, `packages/`) and letting purity fall out of
the dependency graph, which the compiler already enforces.

## Test doubles

`fake.rkt` and `dry-run.rkt` sat beside real code. Every reader of that
tree had to know which files to skip. Fakes belong in a clearly marked
place (`testing/`), so the production tree reads as production code
without a filter.

## What is NOT a violation

- A short name for a short thing. `cancel.rkt` at 44 lines that does
  exactly one thing is honestly named.
- A name that is boring and accurate. `read-lockfile.rkt` is dull and
  tells you everything.
- Domain vocabulary, once it is defined. `generation` and `hold` mean
  specific things in this ecosystem and are documented; that is fine.
  What is not fine is a name that means nothing *outside* its file.