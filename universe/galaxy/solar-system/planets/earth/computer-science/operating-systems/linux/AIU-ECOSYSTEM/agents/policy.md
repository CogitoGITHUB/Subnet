# Policy — one pure module, gate-enforced

Learned building pm's `core/security.rkt` plus gate stage 15 (D-037).
The rule: security questions are answered by total predicates in ONE
module with no I/O, enforced at choke points that refuse with
messages, and a lint stage fails the build when a rule is unwired.

## The module shape

- One predicate per rule, each **total** (never raises) over its
  contract: pin shape, origin allowlist, path containment, symlink
  target, install modes, credential presence, state-changing set.
- No I/O, no environment sniffing, no clock. Pure means exhaustively
  testable: every accept and every refusal gets a case, including
  adversarial ones (`/prefix-evil` vs `/prefix`, uppercase hex,
  39-char pins, password-bearing URLs, empty strings).
- No other module answers a security question. Existing helpers that
  do (a `path-inside?` in git code, an ad-hoc mode check in lowering)
  get rewired to delegate, keeping their names for their callers.
  Duplicated policy is how rules rot.

## The choke points

- Call the predicate where the work happens, refuse with the RULE'S
  NAME in the message (`[source-trust]`, `[origin]`, `[path-escape]`,
  `[install-mode]`), so a refusal teaches the rule.
- Refusals carry kind + exit code + hint, never silence. A skipped
  check is a SKIP event with the reason, not an absence.
- Fail closed at every boundary: unresolvable symlink targets refuse
  (they cannot be checked); unknown modes refuse (never widened or
  narrowed downstream); moved pins refuse (want vs got, both named).

## The gate stage (the teeth)

Two checks, both with file:line answers:

1. **Every policy predicate must be called** outside the policy module
   in non-test code. A predicate nobody calls is a rule nobody
   enforces. Proven by deleting one call and watching the gate go red.
2. **Effects are audited**: file writers and process spawners may only
   appear in a named list. A new writer/spawner anywhere else fails
   until it is written down deliberately. Dev scripts get their own
   named section, not a blanket pass.

Precision matters more than coverage: a lint that flags a caller's
own port as a violation gets allowlisted and then protects nothing.
Narrow each rule until its hits are all real, then switch it on by
default. An opt-in lint that never ships is decoration.

## What we got wrong first

- Policy spread across validators: same rule decided three ways in
  three files. Centralize, then delegate.
- A predicate with no caller: written, tested, never wired. The gate
  check exists because of exactly this failure.
- Type-narrow predicates (`string?` only) breaking path-passing
  callers: coerce at the boundary, keep the core strict.
