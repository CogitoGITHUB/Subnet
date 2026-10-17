# AGENTS.md — how to build in the AIU ecosystem

Applies to every project under `AIU-ECOSYSTEM/` (pm, Node notation,
editor, TM, OS tooling). The ecosystem ReadMe states the design laws;
this file and `agents/` turn them into build rules that survived
contact with a real implementation (the package manager).

## Read this first: `HARD-RULES.org`

Those rules are **binding**, not guidance. Each one is written so a gate
can check it mechanically. If you find yourself breaking one, either
the rule is wrong — say so and change it deliberately, naming the old
number — or the code is wrong. Do not quietly drift.

In short:

1. **Complete and precise output.** Every operation narrates what, why,
   how, when. Anything that can block says so *before* it blocks.
   Refusals name their rule. Asking "what would this do?" is a normal
   operation, not an error.
2. **AI integration from day one.** Engine, MCP server, skill, and
   OpenCode plugin ship together or the project is not done. One JSON
   shape for all four. Read is free; mutate needs a human, and the
   engine re-checks the confirmation itself.
3. **Names say what the thing does.** No `core/`, `engine`, `utils`,
   `manager`, `handler`. A name that lies costs more than a missing
   comment. One file, one job. Stages and checks are named too:
   `text-lint` with `text-lint/line-length` sub-stages, never `stage 6`.
   The reader test, in every project: the owner must never have to ask
   "what is that, why is it there?" about a file, dir or identifier.
4. **Nushell for gates and scripts. Output is data.** Every command can
   emit JSON with a fixed key order. Errors are exit codes, not error
   objects. Doc examples execute in the test suite, so they cannot rot.
5. **Finish means finished.** One item one commit, DONE and the hash
   together. A blocked item never stops the run. Never commit a tree
   that cannot load. No timers, ever.

## The laws, operationalized

1. **Nothing important is silent** → every operation narrates through
   one path. See `agents/narration.md`.
1a. **If it can block, it says so first** → the verbose ten, and the
   discipline that separates it from step-logging. See
   `agents/verbosity.md`. This is not optional and it is not a debug
   flag; a silent block is the one failure mode that costs more than
   every other bug put together.
2. **Nothing important is irreversible without a record** → stepwise
   work is journaled by content hash; re-runs skip with reasons.
   See `agents/reversibility.md`.
3. **Policy lives in one pure place, and the gate enforces it** →
   rules as total predicates, choke points that refuse with messages,
   a lint stage that fails when a rule is unwired. See `agents/policy.md`.
4. **AI is a first-class operator, not a bolt-on** → one JSON surface
   read by CLI, MCP, skills, plugins and fuzzy finders alike; read is
   free, mutate needs a human. See `agents/surfaces.md`.
5. **Decisions are written down with defaults** → D-numbered log,
   options with a recommendation, the default marked when used.
   See `agents/workflow.md`.

## What transfers between projects

- The event schema (field list in `agents/narration.md`). Lift it
  verbatim: feeds from different tools stay mutually readable.
- The journal-resume shape (input-hash-keyed steps, SKIP-with-reason).
- The policy-module-plus-gate pattern for anything safety-relevant.
- The read-free / mutate-gated split for every AI surface.
- The naming law: the reader test, the banned list, and the
  register-first repair of an old tree (section 3).

## What does NOT transfer literally

- Racket mechanics (contracts, parameters, custodians). The shapes
  transfer; reimplement them in the host language.
- Anything marked as a workaround in its own comment. Workarounds are
  local; patterns are portable. If a comment says "precedent", it is
  load-bearing history, not a pattern — read it before touching the code.

## Adding a new ecosystem project

1. Copy this file and `agents/` as the starting point.
2. Write the decision log from day one (D-001 is cheap, archaeology is not).
3. Emit the event schema from the first operation, before any UI.
4. Enumerate your project's blocking primitives and put every one of
   them behind the wait door **before** you write a blocking feature —
   not after your first hang. See `agents/verbosity.md` rule 2.
5. Keep one scope seam for environment/roots; nothing else reads HOME.
6. Ship a skill file alongside the CLI the day commands start working.
7. Write the file inventory and the naming register before the tree
   grows: one line per file and directory, the job it does, why it
   exists (pm's `plan/FILE-INVENTORY.org`, `plan/NAMING-REGISTER.org`
   are the model). The reader test applies from the first commit —
   no path, directory, or identifier may make the owner ask what it is.

## Session rules

# one session per project; the rest of the vault is read-only.

- One session per project. A session works its own project directory
  only; the other projects and `AIU-OS/` are read-only (AIU-OS/AIU-PM
  carries a live session of its own).
- No sub-agents.
- Phone-light: read in small pieces, never whole large files; reports
  20 lines max, real output only, "not run" where not run.
- No test files and no test runs in the three new projects until the
  owner says tests start; until then the light gate only: paren-check,
  text-lint, the naming register (DECISIONS.org D-001 holds the risk).
- Each project's `AGENT.md` repeats these beside its own details;
  `WORKFLOW.org` is the workflow; owner questions are asked once, with
  options and a recommendation.
