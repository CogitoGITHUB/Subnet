# Workflow — decisions, gates, and finishing

Learned running pm's engine build to green. This is the process layer:
how work is ordered, recorded, and verified. It applies to any
ecosystem project regardless of language.

## Decisions (D-numbers)

- Numbered, append-only log, newest first. Every entry names the rule
  IDs it touches.
- For each owner call: the question, 2–3 options, a recommendation,
  and the DEFAULT that applies silently. Mark defaulted items when
  built so the default stays visible afterward.
- Open decisions live in a separate index (id, state, purpose,
  blocker, dependencies) so "what needs the owner" is always one file
  away. Phase the undecided work last; never let it block the decided.
- Contradicting an old decision is allowed; silently drifting from one
  is not. Supersessions name the old number explicitly.

## Checklists

- One driver file listing every item with state: TODO, DONE (with
  commit hash, in the same commit as the work), BLOCKED (with reason),
  PARTIAL (with exactly what is and isn't done), PARKED, REMOVED.
- A BLOCKED item never stops the run: record the reason, skip to the
  next independent item, keep going. Hard stops only for contradictions,
  out-of-tree touches, or missing tools.
- One item, one small commit. The DONE mark and the hash land together.

## Gates

- One shared-process test runner for everything; a slow file is an
  error to investigate, never a reason for tiers or exemptions.
- Lint stages are precise or they are off: tune until every hit is
  real, prove each stage bites (deliberate violation → red with
  file:line), then switch on by default. An opt-in lint is decoration.
- Between items run the changed-files gate; the full gate runs once
  per phase, detached, reconciled on its completion notice. Never poll
  for completion; never use a timer where an event (or a completion
  hook) exists.
- The verdict is one line: green version, files/failed/total, parked
  list. Anything else is commentary.

## Tests

- Synthetic fixtures only, temp roots only, nothing touches the real
  home/state/network. Network-touching tests use local repos.
- Golden tests for every stable output (CLI text, JSON key order,
  feed line shape). Docs that show output re-render it in the suite.
- Failures assert the MESSAGE, not just the code. A refusal that
  doesn't name its reason is untested.
- On-device reality: phone/proot process-spawn cost dominates suites
  that spawn git. That's environment tax, not a code defect — measure
  before "optimizing" the engine for the test harness.

## Debugging (bought expensively)

- Reproduce minimally before touching the repo; bisect which file or
  ordering triggers it; instrument a COPY, never the original.
- Read-check after every edit; on paren failure, rewrite the whole
  function with closing parens isolated, verify standalone, splice in.
- Stale bytecode lies: after contract changes, recompile before
  trusting a test result. A mysterious contract mismatch right after
  an edit is the cache, not the code.
- `raco test` may report passes alongside an uncaught exception; the
  shared runner counts it failed. Trust the runner.
- Shared-process order effects are real bugs, not flakes: a test that
  passes alone and fails in suite is leaking or assuming. Bisect the
  prefix, fix at the source, add the regression to the owning module.
