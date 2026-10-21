# AIU BROWSER

A file panel for the AIU editor: a keyboard-driven tree of a directory, in the shapes
oil.nvim, nvim-tree and telescope gave Neovim, built here with Racket for the meaning and
Rust for the hot path.

It is a first-class citizen of the AIU ecosystem, not a Neovim plugin.

**Nothing is built yet.** The plan is written, the rules bind from the first commit, and
the three studies are done. What is here is the intent, the boundaries and the order.

## Purpose and boundaries

The browser owns the listing of a directory, the tree of directories, the rows and what
each row says, the file actions, the journal that makes them undoable, and the picker
over a named source.

What belongs elsewhere:

- the buffer, the point and the session belong to the editor;
- the panel's placement data is the editor's placeable piece model, not a new one;
- the Git state per row is read from the shared Git layer, not from a second parser;
- the picker is shared with the editor's `picker/` area.

The rules it obeys, one file each in `rules/`:

- **rule 01, never lose work** — every action that changes the tree is written as it
  happens and can be undone.
- **rule 03, no daemon, no timers, no watcher** — the panel is drawn when something
  happens, never on a clock.
- **rule 10, free UI placement** — the panel names an edge, a width and an order, so it
  can sit on any edge of any program that hosts it.
- **rule 13, keyboard driven** — no modifier keys, the trigger is the space.
- **rule 14, the general editor first** — the browser serves the editor.

## Current status

| Capability | State |
|---|---|
| The goal, the non-goals, the architecture, the outputs | Planned: written in `plan/` |
| The rules | Planned: written, and they bind from the first commit |
| The three studies: oil.nvim, nvim-tree, telescope | Implemented and verified: the lessons are written down in `study/` |
| The first slice: the tree and the light gate | Planned (build order step 1) |
| The listing, the rows, the panel | Planned (step 2) |
| The keys and the live session | Planned (step 3) |
| The tree actions and the journal | Planned (step 4) |
| The placement as a placeable piece | Planned (step 5) |
| The picker and its sources | Planned (later in the build order) |
| The git state per row, the branches, the commits | Planned: they will read the shared Git layer |

## Architecture

The split is the editor's split (rule 09, decision D-007): **the hot path is Rust, the
meaning is Racket.**

- **Rust owns the hot path:** listing a directory (readdir, stat, sort), drawing the rows,
  and reading the keys. A tree with 50 000 files is a loop, not a list of hashes.
- **Racket owns the meaning:** what a row *is* (name, kind, size, git state, whether it
  is the file being edited), what a key *means* (the command table), what a change
  *needs* (a why, a checkpoint, a confirmation), and how it all *speaks* (the event
  record).

The seam is one line of JSON each way, exactly as in the editor, and the one-way lint
and the language-split lint keep every other area clean.

The benefit of Rust here is real but bounded: the listing and the paint are the only hot
parts, and they are hot the way the editor's text state is hot. Everything else would
have been slower in Rust, not faster.

## What is planned

**The file panel**, from oil.nvim: a placeable piece instead of a floating window; rows
with a kind and a size instead of icons; the git state per row; opening a file in the
editor through the editor's MCP surface; new file and new directory, journalled and
undoable; rename, delete, move and copy, each asking for a why; a key that toggles the
hidden files; a drop target for files. Dropped: the mouse, Neovim's Lua plugins, and
`oil://` buffers — a path is a path.

**The tree**, from nvim-tree: nodes that open and close as the cursor moves through them;
`find`, fuzzily; `root` to change the root to the parent; `collapse` to fold the tree;
the live `filter` that narrows the rows as it is typed; `cut`, `copy` and `paste` with a
clipboard shared between the panels; the git state and the file kinds per row. Dropped:
the diagnostics per file (the language side belongs to the editor) and the automatic
updates (a watcher), because there are no timers here.

**The picker**, from telescope: find, filter, preview and pick over a **named source** —
a source is a row in a table, not a plugin; the results narrow as you type; the preview
of the item under the cursor (the first lines of a file, the last commit of a branch); the
sorters as a named distance function, so the ranking can change without touching the
finder; a batch pick, because cut, copy and move need it; the placement on any edge, by
data; and opening in the editor, or in a pane — the multiplexer owns the panes.

**The task table**, in the editor's shape: a task is a plain function on the meaning side
that takes the session and the string arguments and answers one line, and its doc line is
the comment block above its own definition, so the list and the help come from the source
and never from a second list. The names that will be declared:

`list`, `open`, `new`, `rename`, `delete`, `move`, `copy`, `hidden`, `where`, `git`,
`find`, `collapse`, `root`, `focus`, `filter`, `cut`, `copy`, `paste`, `branches`,
`commits`.

A name the table does not hold is refused by name. A dry-run scope prints what a task
would do and changes nothing. Every task that acts writes to the journal, with a why. The
table will live in `browser/src/commands/tasks.rkt`.

## Open questions

The project's own decision file carries them, each with the options and a
recommendation; the recommendation is the working assumption until the decision is made.

- **What the panel shows when it opens.** The last directory used, the directory of the
  file being edited, or the tree root. The recommendation is the directory of the file
  being edited, and the tree root when there is no file: the panel is always about the
  work at hand.
- **The rows' order.** By name, by kind then name, or by git state then name. The
  recommendation is by name, with the directories first — the order a person reads a
  directory in.
- **The size of a row.** Bytes, a rounded size, or nothing. The recommendation is a
  rounded size, because a byte count is noise past four digits.
- **Whether a delete is undoable by the journal or by a copy.** The recommendation is a
  copy for a delete, and the journal for everything else.

## Public interface

None yet: there is no code. What the program will offer is the task table above, the
placement data (an edge, a width, an order), the event feed, and an MCP surface with the
same names the ecosystem uses.

## How it works

The plan, in build order, with the reason each step is there:

1. **The tree and the light gate.** Everything else is proved by the gate, so the gate
   comes before the code it watches.
2. **The listing, the rows, the panel.** The first slice: one directory, listed, with the
   meaning on the Racket side and the drawing on the Rust side. This is the smallest
   thing that is already the program (rule 11).
3. **The keys and the live session.** The panel is useless without a cursor, and the
   cursor is a key.
4. **The tree actions and the journal.** A browser that cannot change anything is a
   listing; a browser that changes things without a journal loses work (rule 01).
5. **The placement.** The panel as a placeable piece, on any edge of any host.
6. The picker and its sources, and the git state per row.

## Usage

There is nothing to run yet. The nearest thing to a worked example is the study of the
three programs it takes its shapes from, in `study/oil.org`, `study/nvim-tree.org` and
`study/telescope.org`, each one a table of what is kept, what is dropped, and why.

## Dependencies and integration

- It will be hosted by the editor: the panel is a placeable piece in the editor's
  dashboard, or a pane beside the editor in the multiplexer.
- It will open files through the editor's MCP surface, not by writing to the editor.
- The git state per row, the branches and the commits will be read from the shared Git
  layer (`../shared-layers/git-inspection`), so there is one Git parser in the ecosystem.
- The clipboard is shared between panels, so several panels can work on the same tree.

## Validation, invariants, and error handling

- Every action that changes the tree is journalled with a why, and can be undone.
- A delete is undoable by a copy; everything else by the journal.
- The task table is data in the source: the list and the help are read from it, and a name
  the table does not hold is refused by name.
- The dry-run scope prints what a task would do and changes nothing.
- There is no watcher and no timer: the panel is redrawn when something happens.

## Testing and verification

The phone-first tests are planned in `plan/phone-first-tests.org`, and the gate comes with
the tree, in the ecosystem's usual shape: the paren check, the text lint, the naming
register, the banned words, the one-way lint, the security gate and the language split.

Nothing is verified here yet, because nothing is built.

## Limitations

- Nothing is implemented; every capability above is a plan.
- The panel's placement depends on the editor's placeable piece model, so the browser
  cannot be finished before that piece model is stable.
- The git state per row depends on the shared Git layer's model, so the two programs
  cannot disagree about what a file's state is.

## Roadmap

`plan/build-order.org` is the order, `plan/tasks.org` the task table, and
`plan/open-decisions.org` the questions still owed. The rest of the plan is in `plan/`:
`goal.org`, `non-goals.org`, `architecture.org`, `outputs.org`, `risks.org`,
`reused-vs-written.org` and `phone-first-tests.org`.

## Related documentation

- `HANDOFF.org` — what a fresh conversation needs to start here.
- `TODO.org` — the one list of what is left.
- `INDEX.org` — every file in this directory, with its job.
- `plan/package-tree.org` — the register: every planned file, one job each.
- `plan/naming-register.org` — the names and why they are the names.
- `rules/` — the hard rules, one file each; they bind from the first commit.
- `decisions/first-slice.org` — the choice already made.
- `study/` — the three studies the shapes come from.
- `../DECISIONS.org` — the decisions that cross programs.

## Development

There is no build yet. When the tree lands, the conventions are the ecosystem's: register
a name in `plan/package-tree.org` before you use it, one file, one job, a require may
point downward only, commit with explicit relative paths, never `git add -A`, and a
commit leaves the gate green.
