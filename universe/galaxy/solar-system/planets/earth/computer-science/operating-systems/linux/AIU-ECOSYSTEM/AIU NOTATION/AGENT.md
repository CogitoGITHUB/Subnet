# AGENT.md — session rules for AIU NOTATION
# One job: what a session may do, and must never do, while working this project
# Status: current; changes only through a root decision.

## Scope
- Work only inside this project's directory. The other projects and AIU-OS are read-only; AIU-OS/AIU-PM carries another live session.
- One session per project; no sub-agents.
- Phone-light: read in small pieces, never whole large files; reports ≤20 lines, real output only.

## Tests: not yet
- No test files and no test runs until the owner says tests start; the choice and its risk are recorded in the root DECISIONS.org (D-001).
- Until then the light gate only: paren-check, text-lint, the naming register.

## Building
- The package lives in its own subdir (notation/); the whole tree and every name are planned in plan/PACKAGE-TREE.org. Register first: a name that is not there does not exist yet.
- Comment everything. One file, one job; one topic per directory; an index per directory, updated in the same commit as any change in it.
- Nothing is "done" without real output.

## Git
- Small commits; explicit relative paths of your own files only; never git add -A; no pushes unless the owner asks.
- If git reports a lock, wait and retry; never force.

## Rules that win
- The root HARD-RULES.org, this project's rules/, and the contract before anything that crosses projects.
- The contract changes only through the root decision log (DECISIONS.org).
