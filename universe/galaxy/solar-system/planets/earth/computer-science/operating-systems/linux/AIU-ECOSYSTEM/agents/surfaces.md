# Surfaces — one JSON truth, many readers, gated mutation

Learned wiring pm's CLI, MCP server, skill, OpenCode plugin and
television channels over identical documents. The rule: the engine
owns every decision; every surface is a reader, and mutation crosses
exactly one human gate.

## One surface

- Every command emits the same envelope (`name`, `format`, `operands`)
  plus its result keys, in a fixed key order, one object per line.
  Key order is a contract: readers diff on it.
- The authoritative doc for the surface doubles as its test: re-render
  every documented example against the real code in the suite, so a
  stale example fails the build. Documentation that can't rot.
- New commands extend the table; the table is data (name, arity,
  mutating-or-not), and a test asserts the discovery table and the
  enforcement set agree on every entry. A command in one and not the
  other is a bug, caught mechanically.

## Readers (all of them, none special)

- **CLI**: parses, prints through the single result printer, exits
  with the kind's code. Errors have no JSON envelope — non-zero exit
  instead of a half-formed object. Deliberate.
- **MCP**: JSON-RPC over stdio, one object per line. Read-only tools
  run free. State-changing tools require the session's confirmation
  token; without it the refusal names the token. Malformed input is
  always a JSON-RPC error, never an exception out of the handler.
- **Skills**: usage rules plus worked examples that EXECUTE against
  the real CLI in the test suite. A skill that can't run its examples
  is fiction.
- **Plugins (OpenCode and friends)**: read-only tools over the feed
  file; file watcher, never polling; partial lines left for the next
  write; truncated files restart the cursor. No state-changing tools
  at all — an agent that wants mutation must go through the human gate.
- **Fuzzy finders (television)**: channel configs that call the CLI's
  JSON through Nushell and hand selections back as values. Read-only
  channels; mutating actions hand off to scripts that run the normal
  confirmation flow. Never a one-keypress apply.

## The human gate (non-negotiable shape)

- Preview/dry-run first, always: the full plan prints and nothing
  changes. Applying requires an explicit, separate confirmation.
- Approval at one layer is never authorization in the engine. The
  engine re-checks the token/policy at its own boundary every time.
- Denial stops everything. No fallback to an unguarded path.
- The engine never waits for the AI: no listener changes nothing, a
  slow listener blocks nothing.

## What we got wrong first

- A second JSON shape for the AI feed: two formats, two drifts. One
  file, one schema, readers adapt.
- Pushing events into sessions: needs SDK types that may not exist.
  A verifiable passive digest (system context) beats a guessed active
  push.
- Error envelopes in JSON: a machine that must distinguish "empty
  result" from "refused" needs the exit code, not a richer object.
