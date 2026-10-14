# AGENTS.md — how to build in the AIU ecosystem

Applies to every project under `AIU-ECOSYSTEM/` (pm, Node notation,
editor, TM, OS tooling). The ecosystem ReadMe states the design laws;
this file and `agents/` turn them into build rules that survived
contact with a real implementation (the package manager).

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
