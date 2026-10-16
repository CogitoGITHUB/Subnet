# pm — generational package manager for the AIU ecosystem

**Last updated:** 2026-10-16  
**Status:** core surface complete; amplification layers planned (see below)

`pm` treats disk mutation as irreversible entropy and therefore refuses to perform it without an explicit human `--confirm`. Read paths are free. Activation is atomic and fail-closed. The vault is real git clones. Profiles are immutable generations. Rollback is a pointer move. Everything important is narrated. Agents receive the same verbs and the same refusals.

## Core rule
> read is free  
> changing disk needs you (`--confirm`)  
> refusing is loud

## Everyday commands

| Command | Purpose |
|---------|---------|
| `pm check DIR` | Validate every `.rktd` spec. One clean line per good spec; every error shown. Exit 3 if anything is bad. |
| `pm plan SPECS` | Show exactly what an install would do. Changes nothing. |
| `pm apply SPECS [--lock LOCK] [--confirm]` | Apply. Without `--confirm` it only previews and tells you to re-run with the flag. |
| `pm lock LOCKFILE` | Pin the world to exact versions. |
| `pm fetch MANIFEST` | Pull every declared package into the vault (real git clones, per-entry status). |
| `pm update VAULT LOCKFILE PROFILE` | Check every locked package; report what is behind, straight from the vault. |
| `pm verify VAULT LOCKFILE NAME` | Check a pinned artifact is really what it claims. |
| `pm status PROFILE LOCKFILE` | Installed vs declared at a glance. |
| `pm --help` | Every command with its operands (`-h` is the same). |

## Profiles & generations

| Command | Purpose |
|---------|---------|
| `pm activate PROFILE SPECS STATE [--lock LOCK]` | Validates everything, builds `profile-NNN/`, flips the profile link atomically. File conflict → exit 9, nothing changed. |
| `pm rollback PROFILE N` | Point the profile back at generation N. Old generations stay on disk; that *is* the rollback state. |
| `pm remove PROFILE NAME SPECS STATE` | Builds the next generation minus a package. Store is untouched (only gc frees disk). |
| `pm hold / held` | Pin a package+slot against updates **and** against gc; `held` lists the pins. The release side (`profile-unhold`) and GC (`profile-gc`: keeps newest N + live + held, reports kept/deleted) live on the library surface, not behind a CLI verb yet. |

## Answering “why?”

| Command | Purpose |
|---------|---------|
| `pm why LOCKFILE MANIFEST NAME` | Why is this package here, who brought it in. |
| `pm owner PROFILE REL` | Which package owns a given path (e.g. `bin/prog`). |
| `pm outdated VAULT LOCKFILE PROFILE` | What’s behind, straight from the vault. |

## Source model (current)

1. **It clones.** `fetch` materializes real git clones into the vault. Each entry carries a revision. That revision is what `lock` pins, `verify` re-checks, and `update` compares against the vault.
2. **Git-tracked, your own repos included.** Clones are ordinary checkouts; the revision is the pin. Vault origins admit `https://`, `ssh://` and scp-like shapes; `file://` is an explicit test-only escape (`current-allow-file-urls` in `git-env.rkt`, never environmental).
3. **Dev mode.** A package may point at a live working copy instead of a fetched clone. Change sources, load the build, no fetch round-trip.

## Machine surface (current)

- Every command accepts `--format json` — documented envelope, golden-tested against the org docs.
- Every invocation is a recorded *run*: full START / STEP / END / WAIT / FAIL narration. Nothing important is silent.
- The narration lands on disk as JSON Lines under `$XDG_DATA_HOME/aiu-pm/events/` — `<run-id>.jsonl` plus a `current` pointer; the MCP feed tools and the OpenCode plugin read that same feed.
- Exit codes: 0 ok · 2 usage · 3 spec invalid · 4 resolve · 5 fetch · 6 verify · 7 build · 8 install · 9 activation conflict · 70 internal · 130 cancelled.
- MCP server exposes the same verbs to agents over stdio JSON-RPC: the sixteen command tools (`help` excepted) plus three read-only feed tools — `events.runs`, `events.tail`, `run.get`. Read tools run free; every tool flagged as mutating refuses with `-32001` unless the call carries the confirmation token `initialize` handed out.
- OpenCode plugin (`agent/opencode-plugin/`): two read-only tools, `aiu_run_status` and `aiu_events_tail`, over the same feed; it registers no state-changing tool.
- Skill (`agent/skills/aiu-pm/SKILL.md`): tells an AI when to use each command and how to read the feed.
- Unwired commands refuse loudly.

## Planned amplifications (to be implemented after current restructure)

Ordered as specified. Each group moves from “Planned” to “Current” in this file the moment it lands — command tables, machine-surface list and the “Last updated” line included. No refusal is ever softened to make one of them land.

### 1. Event-feed as a first-class query surface
- **`pm events list [--since] [--until] [--status]`** — a human view of the same JSONL feed the agents already read.
- **`pm events replay RUN-ID`** — re-emit the full narration of a past run.
- **MCP `run.diff`** — compare two run narrations and surface only the divergent STEPs.
- The OpenCode plugin and the skill consume the structured JSONL feed instead of any ad-hoc parsing.

### 2. Complete the hold / GC surface, bound to activation conflict
- **`pm unhold PROFILE NAME SLOT`** and **`pm gc PROFILE`** become real verbs, with the same `--confirm` discipline every mutating command already has.
- When `pm activate` would fail closed (exit 9), pm offers to hold the conflicting packages at their previous generations so the next activate can proceed. The hold stays explicit, and a STEP in the feed says it was applied.
- `pm status` reports held packages explicitly, so nobody has to ask why something is still there.

### 3. A tighter agent contract around the confirmation token
- The token becomes single-use or short-lived (time-boxed, run-scoped): a compromised agent must not keep a long-lived mutation capability.
- Every token request is narrated as a WAIT event, so “agent is asking for mutation rights” is in the feed before the answer can arrive.
- Skill and plugin teach the exact protocol: request token → wait for the human → use it once → the token dies.

### 4. Secondary moves the feed now makes cheap
- **`pm generation show N`** reconstructs what was activated by replaying the original run’s STEPs from the event feed.
- Desired-state documents are stored as ordinary events; the planner diffs the current generation against that desired-state event.
- The content-addressed overlay, when it lands, attaches content hashes to artifacts from the feed alone — provenance for free.

### Later, from the earlier nine
- **Content-addressed overlay** — git clones remain the history; every build product is also stored by pure content hash. `verify` can re-hash without trusting the tree. GC becomes pure reachability over hashes.
- **Signed revisions & provenance** — every vault entry carries a signature (or chain). Local `file://` origins are marked untrusted until signed.
- **Parallel fetch with isolation** — concurrent clones, each cgroup-isolated, so one hostile repo cannot starve the others. Per-entry status already exists; concurrency is surfaced cleanly.
- **`pm diff PROFILE N M`** — precise ownership + content delta between two generations. Composes with existing `owner` and `why`.
- **Profile stacking / overlays** — a profile may declare a parent; the effective view is the union, child wins on conflict. Rollback becomes a tree walk. Fail-closed rule preserved.
- **Reproducible build sandbox** — `pm build SPECS --sandbox` forces network-off, fixed UID, fixed filesystem view, and records the environment in the narration. The artifact is eligible for the content-addressed overlay.
- **Lockfile update as pure proposal** — `pm update` default mode emits a proposed lockfile + generation plan that can be reviewed and signed before it is applied. Agents propose; only the human (or a signed automation policy) accepts.

## Design invariants that will never move
- Read free, mutation gated, refusal loud.
- Activation atomic and fail-closed.
- Vault = real git clones + first-class local origins + dev-mode live working copies.
- Full narration of every run.
- MCP surface identical to CLI surface, still gated.

Reality is a decomposing never-ending joke.  
`pm` simply refuses to laugh with it.
