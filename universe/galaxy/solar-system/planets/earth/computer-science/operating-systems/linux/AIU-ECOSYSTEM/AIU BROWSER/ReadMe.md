# AIU BROWSER

**One job: a file panel for the AIU editor — a keyboard-driven tree of
a directory, in the shapes oil.nvim, nvim-tree and telescope gave
Neovim, built here with Racket for the meaning and Rust for the hot
path.**

## What it is

A file browser that is a first-class citizen of the AIU ecosystem, not a
Neovim plugin:

- **A panel, not a popup.** The placement is data (rule 10): the panel
  names an edge, a width and an order, so it can sit on any edge of any
  program that hosts it — the editor's dashboard, or a pane beside the
  editor.
- **Keyboard first, no mouse anywhere.** The same plain keyboard the
  editor uses: no modifier keys, the trigger is the space (rule 13).
- **Nothing is lost.** Every action that changes the tree is written as
  it happens and can be undone (rule 01); a rename is a rename that can
  be taken back.
- **No daemon, no timers, no watcher.** The panel is drawn when
  something happens, never on a clock (rule 03).

## What it does

Three Neovim plugins, three shapes. What is kept, what is dropped, and
why — in one table each, so nobody looks for a dropped feature later.

### From oil.nvim — the file panel

| oil.nvim | here | note |
|---|---|---|
| a floating or pinned file window | a placeable piece | data placement, any edge (rule 10) |
| icons, file kinds, sizes | rows with a kind and a size | plain text, no colour needed |
| git status per file | the git state per row | read from the tree's own git |
| open a file | open it in the editor | through the editor's MCP surface |
| new file, new directory | new file, new directory | journalled, undoable |
| rename, delete, move, copy | rename, delete, move, copy | each one asks for a why |
| toggle hidden files | toggle hidden files | one key |
| drop target for files | drop target for files | a paste, in the same journal |
| mouse to click | **dropped** | the keyboard is the way (rule 13) |
| Neovim Lua plugins | **dropped** | this is a program with a contract, not a plugin |
| `oil://` buffers | a URL-addressed file | a path is a path |

### From nvim-tree — the tree

| nvim-tree | here | note |
|---|---|---|
| a tree of directories, opened and closed | the tree: nodes open and close | the cursor moves through them |
| find a file in the tree | =find=, fuzzily | the picker's job (below) |
| change the root to the parent | =root= | one key |
| collapse all | =collapse= | the tree folds |
| live filtering | =filter= | the rows narrow as it is typed |
| cut, copy, paste, between two instances | =cut=, =copy=, =paste= | the clipboard is shared by the panels |
| git state, file kinds | per row | plain text |
| diagnostics per file | **dropped** | the language side belongs to the editor |
| automatic updates (a watcher) | **dropped** | no timers here (rule 03) |
| several instances at once | several panels, each with its root | the clipboard works between them |
| events and a public API | the event feed and the MCP surface | this ecosystem's names |

### From telescope — the picker

| telescope | here | note |
|---|---|---|
| find, filter, preview, pick | the picker over a named source | a source is a row in a table |
| the results narrow as you type | the live filter | the same thing, one command |
| a preview of the item under the cursor | the first lines of a file, the last commit of a branch | a preview that says what the thing is |
| the sorters | the distance function, named | the ranking can change without touching the finder |
| many sources (files, grep, branches, commits) | the tree, the branches, the commits | the language pickers belong to the editor |
| pick several at once | the batch pick | cut, copy and move need it |
| a dropdown, a cursor list, an overlay | any edge, by data | the placement is data (rule 10) |
| open in a split, a vsplit, a new tab | open in the editor, or in a pane | the multiplexer owns panes |

## Why Racket and Rust, and not only one

The split is the editor's split (rule 09, D-007), and the reason is the
same: **the hot path is Rust, the meaning is Racket.**

- **Rust owns the hot path:** listing a directory (readdir, stat, sort),
  drawing the rows, and reading the keys. A tree with 50 000 files is
  a loop, not a list of hashes.
- **Racket owns the meaning:** what a row *is* (name, kind, size, git
  state, whether it is the file being edited), what a key *means* (the
  command table), what a change *needs* (a why, a checkpoint, a
  confirmation), and how it all *speaks* (the event record).

The seam is one line of JSON each way, exactly as in the editor, and the
one-way lint and the language-split lint keep every other area clean.

The benefit of Rust here is real but bounded: the listing and the paint
are the only hot parts, and they are hot the way the editor's text
state is hot. Everything else would have been slower in Rust, not
faster.

## Where it stands

The plan is written; **nothing is built yet**. Start at `HANDOFF.org`,
then `TODO.org`, then `plan/build-order.org`.

- `plan/package-tree.org` — the register: every planned file, one job each
- `study/` — the three studies: oil.nvim, nvim-tree, telescope
- `plan/naming-register.org` — the names and why they are the names
- `plan/open-decisions.org` — the decisions this project owes
- `rules/` — the hard rules, one file each; they bind from the first commit
- `decisions/` — the choices already made, newest first
