# Plan: Text editor remaining work — AIU EDITOR

## Goal
Complete the remaining TODO.org items for the AIU text editor, after the terminal multiplexer resumes work (priority switch 2026-10-21). Do not implement source changes — this plan is for an implementation-capable agent to execute.

## Constraints
- Editor is PAUSED until multiplexer builds, its gate is green, and persistent sessions + attach/detach are proved on the phone (resume conditions in TODO.org lines 34-38).
- No source edits, no mutating commands, no whole-ecosystem gate (none exists).
- One item, one commit; commit with explicit relative paths; never `git add -A`; a commit leaves the gate green.
- HARD-RULES.org: no banned names (`core`, `engine`, `main`, `utils`, `helpers`, `common`, `base`, `manager`, `service`, `handler`, `misc`, `stuff`, `data`, `types`, `config`); one file, one job; area law (dependency points downward only); language split (only `join/` crosses Rust/Racket).
- No tests for now — light gate only (D-001). Full gate arrives with first test item.

## Remaining items (build order)

### 4 — Key routing walk with editor IN A PANE [PARTLY DONE]
Routing tables built; gate `route-check.rkt` refuses reserved-prefix `C-b` binding and routes naming commands not in the table. Left: run the walk with the editor inside a multiplexer pane — multiplexer owns panes/routing (its TODO item 5).
Deps: multiplexer items 3–4.

### 6 — Editor keyboard live session [PARTLY DONE]
Rust decoding + Racket keymaps done. Left: routing walk inside a live editing session (keys read from terminal, not bytes); `buffer/selection.rkt` still a plan; send action still a stub.
Deps: item 4.

### 18 — Agent opens beside editor [TODO]
Multiplexer pane beside editor's pane; bundle context (selection, file, position) travels with request; editor holds agent's view as a placeable piece (data-driven placement: edge, width, order).
Deps: multiplexer code; item 9 (agent boundary/seam already built).

### 20 — Workspace engine joins editor [TODO]
Key opens project context; mode line names workspace + project (`ws:`, `pr:`); closing editor leaves workspace and multiplexer untouched. Read shared-layers/workspace engine via join seam; editor keeps own tabs/buffers.
Deps: items 15, 18, the engine (shared-layers/workspace, built and verified).

### 15 — Kit conformance across both programs [PARTLY DONE]
Editor's four surfaces (envelope, MCP server, skill, read-only watcher) + capability declaration built; gate `kit-check.rkt` green for editor. Left: multiplexer half so shared checklist runs green for both.
Deps: items 9–14.

### 16 — Done line [PARTLY DONE]
Editor's clauses hold. Left: multiplexer basic version + select/send from mux; notation core hosted in editor (Notation item 11 — editor may not touch it); "to both OpenCode and Hermes" (Hermes skipped 2026-10-20); owner deletes shared `checklist/` (root file, read-only from here).
Deps: all above + Notation item 11.

### 24 — Config reloaded live in dev mode [TODO]
Config change in force without restarting editor; reload on record.
Deps: item 8 (devmode), devloop.

### 26 — Agent's hands on editor [TODO]
Agent drives editor via MCP server: open/close buffer, split/close window, scroll view, copy into editor's ring, paste into another buffer or agent — runs same code owner's keys run.
Deps: items 6, 14, 18, multiplexer item 23.

### Skipped (not to be done)
Item 10 — second adapter (Hermes), closed by owner 2026-10-20.

### Already DONE (not left)
Items 1–3, 5, 7–9, 11–14, 17, 19, 21–25. Git facts/diff/history/bar all cross the seam and verified (items 21–25).

## Validation
Run editor's light gate after each completed item:
```
/root/home/shape/opt/nushell/0.116.1/nu --no-config-file gate/check.nu
```
Gate must be green (14 stages at pause). Build outside tree:
```
cd "AIU EDITOR"
cargo build --manifest-path editor/Cargo.toml --target-dir /tmp/editor-target
rm -f editor/Cargo.lock
```
Rust crate at `editor/Cargo.toml`; Racket entry at `editor/src/entry/cli.rkt`. Builds target `/tmp`, never the tree.

## Open questions / risks
- `contract/` directory and its nineteen contract files referenced by READMEs are NOT on disk (absent at root).
- `checklist/tier-1/` referenced by TODO.org is NOT on disk.
- Multiplexer has no code yet — items 4, 18, 20, 26 blocked on it.
- pm does not run on this phone (Racket package DB unreadable) — plugin-install says so, installs nothing; break is pm's to fix.
- Discrepancy: README says gate green at 14 stages; TODO says 15 stages on `c8b06bca`.