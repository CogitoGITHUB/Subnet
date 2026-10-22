# AGENT.md — session rules for AIU TERMINAL MULTIPLEXER
# One job: what a session may do, and must never do, while working this project
# Status: current; changes only through a root decision.

## Scope
- Work only inside this project's directory. The other projects and AIU-OS are read-only; AIU-OS/AIU-PM carries another live session.
- One session per project; no sub-agents.
- Phone-light: read in small pieces, never whole large files; reports ≤20 lines, real output only.

## Tests: on for this package
- The Rust unit tests run with `cargo test --offline` (46 + 17 + 18 tests, green), and the light gate is green at 8 stages.
- The root hold D-001 ("no tests for now") named the three new projects; the notation's own list records the owner lifting it on 2026-10-19, and this package's tests came with that work. The root log has no separate entry for the multiplexer, so the facts are written here and the log is the owner's to amend.

## Building
- The package lives in its own subdir (multiplexer/); the whole tree and every name are registered in plan/package-tree.org and, for the package itself, in multiplexer/INDEX.org — the register the gate reads. Register first: a name that is not there does not exist yet.
- Comment everything. One file, one job; one topic per directory; an index per directory, updated in the same commit as any change in it.
- Nothing is "done" without real output.

## Git
- Small commits; explicit relative paths of your own files only; never git add -A; no pushes unless the owner asks.
- If git reports a lock, wait and retry; never force.

## Rules that win
- The root HARD-RULES.org, this project's rules/, and the contract before anything that crosses projects.
- The contract changes only through the root decision log (DECISIONS.org).
