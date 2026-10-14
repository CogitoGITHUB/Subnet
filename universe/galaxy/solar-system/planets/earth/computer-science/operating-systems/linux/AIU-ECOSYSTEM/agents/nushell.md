# Nushell and data output — the shell is the tool

Binding version: `HARD-RULES.org` section 4.

## Why Nushell

The gate has to be readable at 3am on a phone, by someone tired, with
no time to reconstruct what a script does. That argues for a shell whose
values are typed and whose pipelines carry data, not text.

Three properties that decided it:

1. **Values, not strings.** `open x.json | get packages | where held`
   works because the pipeline carries structured values. In a
   string-only shell the same query is a pile of fragile text munging.
2. **It is honest about failure.** A closed port is an error, not an
   empty string. That single property is why a gate can be trusted to
   exit non-zero rather than printing a cheerful lie.
3. **It is readable.** A structured format table where each stage prints
   what it did, in order, with a start and an end timestamp.

Rule: **gates and dev scripts are Nushell.** A gate in another language
is a gate nobody can read when it matters.

## Output is data

Text is for humans. Everything else needs structure.

### The envelope

Every command emits the same three keys first, always in this order:

    {"name":"status","format":"json","operands":["default", "pm.lock"]}

then its own result keys. **Key order is a contract** — readers diff on
it, so reordering keys is a breaking change even when the values match.

### The four surfaces, one shape

CLI, MCP, skill, plugin, and fuzzy-finder channels all read the same
document. Two shapes means two things drift, and the one nobody tests
is the one that drifts.

### Errors are exit codes

A refusal exits non-zero and prints its reason to stderr. It does **not**
print a JSON object with an `error` field.

This is deliberate and it is the more honest design: a machine that must
distinguish "no results" from "refused" cannot do it from an object
that might legitimately be empty. Only the exit code carries that
distinction without ambiguity. A half-formed object that *looks* like a
result is worse than a clean non-zero exit.

### Both shapes where both make sense

- **Text**: the default, for a human at a terminal.
- **JSON**: `--format json`, for everything else.

A tool that only prints for humans cannot be composed. A tool that only
prints JSON cannot be used by a person. Ship both, from one code path,
so they cannot drift.

## The gate

```
[check] run start utc=...
[check] stage 6 text lint
lint: 83 files, 0 violations
[check] end utc=... after=8158ms
```

**The verdict is one line**: version, files, failed, total, and the
parked list. Anything else is commentary.

### Gates must bite

Every lint stage is proven by breaking the rule deliberately and
confirming the gate goes red with a file:line. A lint stage that has
never failed has never been tested, and an untested lint either passes
everything or blocks everything.

This is not theoretical. In one session, deleting a single enforcement
call turned the gate red immediately — proving the check was real and
not decorative. A stage that has never been seen to fail is a stage you
do not know the behaviour of.

### No tiers, no exemptions

One shared test runner for everything. A slow test is a thing to
investigate, never a reason to split into fast and slow tiers or to
exempt a directory. Tiers are a way of never running the slow ones.

## Documentation is executable

Every example in `docs/API.org` is parsed and executed by the test
suite. If the code changes shape and the docs do not, **the build
fails**.

This caught four wrong examples in a single session during the command
wiring — all four written by hand, all four wrong. Documentation that
cannot rot is worth more than documentation that reads nicely.

## No timers

No `sleep`, no polling loops, no heartbeats, no `timeout` around a
command that might legitimately take minutes. Wait for an event or a
completion signal.

A timer is a guess about when something will finish. On a phone under
proot, a process spawn costs 0.5–1.5s, so a timer tuned on a desktop
is either a false failure or a wasted wait. The signal is the truth.

A background command ends with an `echo` so completion announces itself
— that echo *is* the signal.