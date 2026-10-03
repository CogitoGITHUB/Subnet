# AGENT.md — Operating guide for this Emacs configuration

**Read this before touching anything.** It exists because the setup has rules
that are not visible from any single file, several of them are silent when
violated, and a few things people reasonably assume are true are not.

Companion document: `CAESTRIA AGENT INTEGRATION INTO CYBERDECK` is the *Cyberdeck API
contract* (how to call the Cyberdeck, what agents may not do). This file is the
*Emacs build* (how the loader works, what the Cyberdeck is, how to test). They do not
overlap.

---

## 1. Orientation

Everything lives under one git repo:

```
/data/data/com.termux/files/home/Subnet/     <- vault root, has .git
```

| Path | What it is |
|---|---|
| `universe/` | the knowledge cyberdeck, mirrored from physical scale down (universe → galaxy → solar-system → earth → … → linux) |
| `…/linux/text-editors/neomacs/Cyberdeck-Emacs/` | the Emacs config source. Everything below this is Emacs. |
| `Cyberdeck-Emacs/AIU-Frame` | Org source, tangled at every boot into `early-init.el` + `foundation-init.el` |
| `Cyberdeck-Emacs/cyberdeck-emacs` | **the loader** (3176 lines) — discovery, ordering, extraction, compilation, caching, doctor |
| `Cyberdeck-Emacs/emacs-cyberdeck/` | the unit tree: ~400 files, ~300 tagged units |
| `admin/` | session + layout state, excluded from unit discovery (see §10) |
| `WIP/` | raw captures. Never read, never walked, by anything. |
| `emacs-mechanism/` | aiu-context/metadata for the mechanism system |
| `~/.config/emacs/init.el` | static seed. Locates the AIU Frame, tangles it, loads `foundation-init.el`. |
| `~/.config/emacs/*.el` | **build artifacts.** Never edit. See §9. |

Environment: Termux inside a proot Ubuntu, Emacs 30.2, TTY only (no GUI), phone
screen. `~` is `/root`, which is the same tree as
`/data/data/com.termux/files/home`.

### Boot chain

```
init.el
  → tangles AIU-Frame (Org)
      → early-init.el          (palette, GC, message filters — pre-init)
      → foundation-init.el     (straight → org → leaf → loader)
          → tangles cyberdeck-emacs
              → discovers + orders + compiles every tagged unit
                  → your config
```

`foundation-init.el` ends by calling `cyberdeck-emacs-boot`. The loader is
the only thing that knows how a unit becomes code.

---

## 2. The loader's rules — these are the non-negotiables

All of this is from `cyberdeck-emacs`, and all of it is **silent** when you
break it.

### A file is a unit only if all of these hold

1. **Its basename contains no dot.** The walk enforces "extensionless" on the
   basename (`:1285-1286`). `dired` loads. `dired.org` and `dired.el` are
   **silently discarded before the file is read**. If a unit goes missing after
   you touch it, check this first.
2. **It is not under `.git/`, `admin/`, or `WIP/`** (`:1275-1279`).
3. **It has a level-1 Org heading tagged `:EMACS_MECHANISM:`**
   (`cyberdeck-emacs--scan-file-tagged-units`, `:844-850`).

Nothing else. There is no per-module directory requirement — see §8.

### The heading is the name

The unit's `:title` is **the level-1 heading text with its tags stripped**
(`:866-870`). Not `#+title:`. The heading *is* the identity.

### The drawer is read for exactly three keys

The property drawer must sit on the line **immediately** after the heading
(`:875` — prose between the heading and the drawer silently detaches it, and
the package is then never built; this is why `doct` was never installed). The
scanner reads:

- `:ID:` — identity, and the cache key
- `:MM_PARENT:` — the parent's **`:ID:`**, *not* its title and *not* its path
  (`:1219`)
- `:MM_ORDER:` — a float, sorts siblings

Nothing else. `:CATEGORY:` is read by **nothing**.

### Ordering has two classes, and only one is path-independent

- **Chained** (has `:MM_PARENT:` or `:MM_ORDER:`) — parents first via a
  cycle-guarded walk, siblings by `:MM_ORDER:`. **Path-independent.**
- **Chainless** (neither) — appended after the chain, **sorted by file path,
  then line** (`:1192-1199`). 120 units are chainless. **Moving one changes its
  load position.**

`:MM_PARENT: none` is the explicit "I am a root". A parent that does not
resolve, a cycle, and a duplicate `:ID:` are each reported at boot — watch for
those three lines, they are the loader telling you a move went wrong.

### `#+`-level file keywords

| Keyword | Live? | Why |
|---|---|---|
| `#+auto_tangle: t` | **yes** — 2 files only | the AIU Frame and the loader are the only org-babel-tangled files |
| `:header-args:` drawer property | **yes** — same 2 files | their tangle targets |
| `#+title:` | display only | `cyberdeck-emacs-file-title` (`:929`) uses it for the splash, falling back to the basename. **Its docstring literally says "Display only".** |
| `#+filetags:` | dead | no reader anywhere in the vault |
| `#+property:` | dead **and misleading** | lexical binding is the single global `cyberdeck-emacs-lexical-binding` defcustom (`:1529`), written into the `.el` cookie at `:1930`. There is no per-file control. |

`#+title:`, `#+filetags:` and `#+property:` were stripped from all of
`universe/` (458 lines, 333 files) on 2026-09-26. Root-level files were
deliberately **not** touched, because that sweep was scoped to `universe/`.

---

## 3. Naming: everything self-describing, nothing plain

**A short name is a bug waiting to happen.** Every plain name in this tree has
already cost something: `order` did not say which bar's order; `stock` did not
say whose stock; `setup` and `macros` say nothing at all; and `dashboard` in
`admin/order/` was genuinely ambiguous with the dashboard module itself.

1. **A filename says what it orders or configures, not which module reads it.**
   `admin/order/dashboard widgets`, `admin/order/modeline widgets`,
   `admin/order/headings aiu-context drawer`. Never `order`, never `drawer`.
2. **Directories say which module owns them.** `cyberdeck-dashboard/`,
   `biomechanical-input-interface/`, `cyberdeck/`. Never a bare `engine/`,
   `core/`, or `aiu-contexts/` at a shared level.
3. **Function and variable names carry their module.** `cyberdeck-dashboard--…`,
   `my/cyberdeck--…`, `manifolding-modeline--…`. A name that could
   belong to two modules belongs to neither.
4. **Never name a file after the module that reads it** when the file means
   something else. A drawer-order file inside the Cyberdeck is a layout file for the
   whole vault, not an Cyberdeck artefact.

The test: **could this path be mistaken for anything else in the tree, and would
grepping for it find only this thing?**

Two naming traps that are load-bearing:

- **A dot in a unit filename makes it invisible** (§2A.1). A dot is fine in
  `admin/`, which the loader never walks.
- **Renaming a unit file changes the loader cache key** for any unit without an
  explicit `:ID:`.

---

## 4. Writing a unit

```org
* Human Readable Name :EMACS_MECHANISM:
:PROPERTIES:
:ID:       <uuid — check it is unused before using it>
:MM_PARENT: none
:MM_ORDER:  80.5
:END:

Prose here is not loaded. Only #+begin_src blocks are.

#+begin_src emacs-lisp
(defun thing () "docstring." 42)
#+end_src
```

- Copy an existing unit's header block; the drawer is not optional in practice.
- `:MM_ORDER:` is a float and **must** be unique — collisions are not
  diagnosed, they just make order arbitrary.
- Prefer `:MM_PARENT: <parent uuid>` over a bare float when you must land after
  something specific.

### Five ways to write a unit that does not work

All of these were done and all of them were caught only by booting, at 6–8
minutes each. See §7 for the loop that finds them in seconds.

1. **The lisp-2 trap.** Inside a quasiquote, `,x` and `',x` are not
   interchangeable. `,cache` splices a *variable reference* (right in `defvar`);
   `',name` splices the *symbol as datum* (right for an `assq` key). And
   `add-hook` wants a variable's **name**, so it needs `',hook` — a bare `,hook`
   passes the value, usually `nil`, giving `Attempt to set a constant symbol`.
   Reference: `cyberdeck-dashboard/engine/macros`.
2. **Nested quasiquotes.** Choosing inside the template (`` `(add-hook (if ,slow
   …)) ``) escapes `,slow` to the wrong depth and splices the *unexpanded* form
   in as data. Compute the value in the macro body and interpolate it.
3. **A bare `cl-lib`/`seq` alias.** `pushnew`, `position` and friends resolve to
   nothing — or to something else — depending on what else is loaded. `position`
   is not a function at all; `cl-position` and `seq-position` are separate
   symbols. Use `member`/`length` or the explicit `cl-`/`seq-` prefix.
4. **A new `#+begin_src` inside an open one.** Large units have a block that
   spans hundreds of lines. Inserting a heading plus a new block inside it trips
   the loader's nesting gate (`heading inside open src block (opened line N)`)
   and the whole unit fails. Either extend the existing block or put your code
   after its `#+end_src`.
5. **A cache key that misses.** `:test 'eq` on a **cons** key never matches:
   two `(cons 1 :left)` calls build distinct objects, so every `gethash` misses
   the `puthash` before it — silently. Use `:test 'equal`, or an alist.

### And the habit that prevents a whole class of it

**Add a lint that fails loudly; do not add a fix that fails quietly.** Five
`**:DASHBOARD_AIU_CONTEXT:` files sat in the tree for months looking load-bearing
because nothing ever asked whether a declared thing was *used*. The dashboard
validator now reports an **orphan file** in `widgets/` that no widget registers,
and a widget registered with no file. A validator that only checks what exists
is not a validator.

---

## 5. What the Cyberdeck is

This is the aiu-taking system, not the Emacs config. Under
`emacs-cyberdeck/files/aiu-registration/cyberdeck/`. Verdicts are from
reading the tree, and many files there are raw Emacs-manual prose with an empty
src block — those are **not** implementations.

| Area | State | Detail |
|---|---|---|
| **AIU factory** | WORKING | `aiu-frame/aiu-registration` — 8040 lines, 252 src blocks, the largest real implementation. `cyberdeck-create/-find/-insert/-visit`, prompt registry, `${var}` / `%(elisp)` template expansion, aiu-context add/edit/nest. |
| **AIU Contexts** | WORKING | `aiu-context/` — ~45 files. Most are **pure vocabulary**: a `:AIU_CONTEXT_DRAWER:` heading plus `** VALUE :AIU_CONTEXT_BODY:` children, zero src blocks. `todo` defines 22 TODO states, `mastery` the stage spine, `status` the lifecycle. |
| **Database** | WORKING | `aiu-frame/db` — 371 src blocks. emacsql. `notes` (id, title, path, level, pos, AIU Contexts, tags) + `links`. Extractor registry with priority. Traversal: `db--bfs`, `db-ancestors`, `db-component`, `db-shortest-path`, `db-isolated`. |
| **Search** | WORKING | `aiu-frame/search-center` (827 lines) — the real surface. `my/cyberdeck-search` is one `consult--multi` over Text (rg, async), DB, Org-ql (7 presets) and Files. **Extensible**: `my/cyberdeck-search-register-provider`, with the candidate contract asserted in code. |
| **Keyword scan** | WORKING | `aiu-frame/search` — vendored `consult-todo`, deliberately not `rgrep` or `hl-todo--search`. |
| **Query language** | WORKING, narrow | `aiu-frame/query-language` — and/or/not, tag, title-match, recent-days, before/after, sort/limit. **No full-text operator.** |
| **Context UI** | WORKING | `sidebar` (20% window, Context/Backlinks/Outline/Due, 2s idle follow), `aiu-view`, `search-center` preview, `aiu-subnet`. `sidebar` has an empty `** Implementation` section from a split-out refactor. |
| **Semantic search** | **dormant by design** | `aiu-frame/semantic-similar` — Ollama `/api/embed` + `bge-m3`, sidecar is a printed Elisp alist, `-similar` is a linear scan, one vector per AIU, and `my/cyberdeck-semantic-enabled` is `nil`. The file says "Nothing here runs at load." |
| **Export** | essentially ABSENT | Only `aiu-subnet/export-json` (an AIU Subnet dump). No org-publish, no HTML, no flatten-to-headings. |
| **LLM question-answering** | ABSENT | Nothing calls a model to answer anything. `ai-proposals` is a generic shell command with no retrieval; `agent-api` is the read/write surface for agents and stamps `PROVENANCE_*`; `plugins/citation` extracts `[@citekey]` into a `citations` table. The two halves exist, the citation-validating join does not. |
| **Dashboard** | PLACEHOLDER | The real dashboard is a separate module under `entering-the-machine/`. Inside the Cyberdeck, "dashboard" is only a declaration registry (§11). |

### The database is fine — do not "fix" it

- `my/cyberdeck-db-backend` defaults to **`sqlite`**
  (`aiu-frame/db:28`) against `admin/cyberdeck.db` — a real file with
  **302 AIUs**. A `pg` backend exists and is fully implemented, and
  `my/cyberdeck-db-health` reports `DOWN` **for pg only**. Seeing `DOWN`
  in a proot batch run means you were looking at the wrong backend.
- **Sync is poll-based on purpose** (`setup:115-120`: "fswatch rarely exists on
  Termux"), so the DB updating lazily is the design, not a fault. There is also
  an after-save autosync and an idle orphan prune where disk is truth.
- PostgreSQL *is* installed and running under Termux; it is just not the default.

---

## 6. Module map

All paths relative to `Cyberdeck-Emacs/emacs-cyberdeck/`.

| Directory | MM_ORDER lane | Role |
|---|---|---|
| `entering-the-machine/cyberdeck-dashboard/` | 78.3–78.5 | dashboard: `engine/`, `cores/` (vendored emacs-dashboard), `widgets/`, `banner/`, `faces`. Its order file lives in `admin/`. |
| `the-screen/modeline/` | 80.1–80.11 | multi-row mode line: `engine/`, `cores/stock`, `faces`, `widgets/`, `header`. Its order file lives in `admin/`. |
| `files/aiu-registration/cyberdeck/` | 100+ | the Cyberdeck — see §5 |
| `…/cyberdeck/biomechanical-input-interface/` | 2.x–4.x | modal key system: `engine/` (state machine, macros, scaffolding), `states/` (15), `leaders/` (19) |
| `the-screen/display/06-screen` | — | raw Emacs-manual prose, parked. Still holds display/windows/frames/Imenu/font-lock |
| `org-manual/*` | — | raw Emacs-manual prose, parked |

The manual-extract files are **intentional placeholders**, not broken config.
`:EMACS_MECHANISM:` is aspirational — it marks a file as a unit you intend to
write. The point of the project is to turn them into real config, carrying the
prose across as you go. Do not "fix" a parked unit.

---

## 7. Testing — the loop, and the two that lie

### The fast loop: seconds, not nine minutes

```sh
neomacs --batch -Q --load /tmp/kilo/bc.el  <file> [<file>…]   # BALANCED / BROKEN
neomacs --batch -Q --load /tmp/kilo/bc2.el <file> [<file>…]   # per-block, names the block
```

`bc.el` extracts each `#+begin_src emacs-lisp` block and byte-compiles it, which
is the same primitive the loader's `--check-unit-parens` uses. `bc2.el` does each
block separately so it can tell you *which* one. **Use these for anything
paren-shaped. A missing paren should never cost a boot.**

Two caveats: a `BROKEN` means "read the message" — `byte-compile-file` also
returns nil for non-paren reasons, e.g. `Cannot open load file "s"` — and ignore
the first line of output, which walks the script's own arguments.

**`/tmp/kilo/check.el` is a hand-rolled scanner and should be deleted, not
trusted.** It had three separate bugs — an empty scan range, string detection
only at column 0, and an infinite loop on nested blocks — each of which would
have silently passed broken code. The byte-compiler is the only paren oracle
worth believing.

### The authoritative loop: the real boot

```sh
neomacs --batch -Q --load /root/.config/emacs/init.el --load /tmp/kilo/noquit.el
```

Takes **6–8 minutes**: ~400 files read, ~300 units compiled. Run it in the
background. Progress prints as `N/300 · Compiling: <name> · E errors · W
warnings` — watch the counter and note which unit it is on.

`noquit.el` detaches the desktop save hook, which otherwise blocks batch runs on
"Overwrite this desktop file?".

A clean boot is **89 packages ok, 1 error** — the one being the pre-existing
`bufler` issue in §11. Higher means you regressed something.

### `eval` of a string does not work here

On this Emacs 30.2 build, `(eval "(defvar xyz-abc 1)")` **defines nothing** and
`(eval '(some-fn))` **returns the list unevaluated**. It reports success and
changes no state. An entire isolated harness of mine was measuring its own
harness and reporting phantom `void-function` errors that existed nowhere but in
the test. **To exercise code, extract it to a `.el` and `load` it.** `load`
works; `eval` of a string silently does nothing.

When an isolated test and the boot disagree, the boot is right.

### After a boot

```sh
grep -o ':level [a-z]*'  ~/.config/emacs/cyberdeck-emacs-errors.log.el | sort | uniq -c
grep -o ':status [a-z-]*' ~/.config/emacs/cyberdeck-emacs-errors.log.el | sort | uniq -c
```

`:status ok` is the health metric. `:level part` entries carry the failing
file, line and package. The three gates — `cyberdeck-dashboard-validate`,
`biomechanical-input-interface-validate`, `manifolding-modeline-audit` — should all be
empty.

---

## 8. Moving files between modules

**Safe.** Discovery is content-addressed, ordering is ID-addressed, and
cross-file references are by symbol. Moving a keyboard state, a leader, a
dashboard widget or a modeline widget will not break the boot or change its load
order.

Three exceptions, all real:

1. **Chainless units reorder by path.** Give anything you move an `:MM_ORDER:`.
   `leaders/tools` currently has none — that is the one to fix first.
2. **`biomechanical-input-interface-validate` scans two hard-coded directories**
   (`biomechanical-input-interface/engine/scaffolding:132-134`): `states/` and `leaders/`,
   non-recursively. Move a state out and the validator silently stops checking
   it. Silence means "not looked at", not "fine".
3. **A dot in the new filename makes the file vanish.** §2A.1.

Scaffolders still *write* to fixed directories, so a reorganisation is not
self-maintaining until those change too.

---

## 9. Never edit these

`~/.config/emacs/early-init.el`, `~/.config/emacs/foundation-init.el`,
`~/.config/emacs/cyberdeck-emacs.el`, and anything the loader writes into its
cache. All are regenerated from `universe/` on every boot.

**Editing a macro does not invalidate its users' caches.** The cache is keyed per
unit on that unit's own content hash, so fix a DSL in `engine/macros` and the
widgets that *call* it keep their stale compiled expansion. Bump
`cyberdeck-emacs-cache-salt` or clear the cache when you change how a macro
expands.

---

## 10. What's in `admin/`

Excluded from unit discovery, which is what makes it the right home for
non-code state.

```
admin/
  order/dashboard widgets           dashboard section order (read AND written at runtime)
  order/modeline widgets            modeline segment order
  order/headings aiu-context drawer  drawer key order + the aiu-context registry (registry NOT built — see §11)
  desktop/                          Emacs session desktop
  cyberdeck.db                   Cyberdeck database, sqlite, 302 AIUs
```

The three order files are named for **what they order**, not after the module
that reads them. Each is reached through one helper, so a reader and a writer
never diverge: `cyberdeck-dashboard--order-file`,
`manifolding-modeline--order-file`, `my/cyberdeck--drawer-order-file` —
all anchored on `cyberdeck-emacs-vault-root`.

Filenames contain **spaces** on purpose. Safe: `admin/` is excluded from unit
discovery, so the loader never touches them. Quote them in shell:
`ls "admin/order/dashboard widgets"`.

**Policy note:** `CAESTRIA AGENT INTEGRATION INTO CYBERDECK` says agents must never
edit anything under `admin/`. That rule predates the move — `admin/` held only
the database and `.known-keys`. Treat the three order files as source and
everything else in `admin/` as generated. That document needs updating.

---

## 11. Known issues

| What | State |
|---|---|
| `bufler` / `auto-workspace` void in `the-screen/buffer-management:86` | **Pre-existing.** The loaded bufler checkout's `bufler-defgroups` macro has no `auto-workspace` clause. The unit carries an interlock (`my/bufler--macro-has-workspace-p`) that skips grouping setup instead of dying. Fix by updating the bufler checkout. This is the 1 error in an otherwise clean boot. |
| **The aiu-context registry is not built** | The design is agreed: one `:AIU_CONTEXT_<KEY>:` property per aiu-context in `admin/order/headings aiu-context drawer`, values relative to `aiu-context/`, order is arrangement, and an interactive sync writes the arrangement into each file's `:MM_ORDER:` by **reusing the numbers those files already own** so no collision is possible. A first sync must report **no changes**. An earlier attempt broke two Cyberdeck units and was reverted; `my/cyberdeck-dashboard-key-files` is a better host for it than `aiu-registration`. Do not re-derive this from scratch. |
| `my/cyberdeck-dashboard-register-all` | **Confirmed dead** — the Cyberdeck's in-dashboard registration sweep runs every boot and finds nothing, because its aiu-context directory does not exist. Roughly 350 lines on the Cyberdeck boot path. Not removed, because deleting it means touching boot. |
| modeline left column | Segments parse but land in the right slot: `read-order` returns rows like `(1 nil (…))`. The `row-N-side` regex is **verified correct** (`row-1-left` → `1`, `left`, and `(eq 'left :left)` is true), so the fault is in the slot assignment below it — untraced. Cosmetic: the bar renders mirrored. |
| modeline audit | Last verified failing on a `characterp` in the right-align padding; a fix landed in `manifolding-modeline-format` (rows are constructs, not strings, so they are interleaved with a literal `"\n"` rather than `mapconcat`-ed) and a follow-up in the audit's emptiness check. Both are balanced; the combination has **not** been confirmed in a boot. |
| `cyberdeck-drawer-key-order` | A **second** source for the same key order the drawer file carries (`("TODO_STATE" "ID")`). They can disagree silently. Reconcile before building the registry. |
| `cyberdeck-emacs-todo-file` | Points at `modules/TODO`, which does not exist. Only affects the interactive "file this boot error as a TODO" escape hatch. |
| `/root/modules` | Dangling symlink to `~/.config/emacs/modules/`, which does not exist. Nothing references it. |
| `links` table empty | 0 rows while `mm-nodes` has data. May be expected; worth a look separately. |
| ~128 compiler warnings | Nearly all in `aiu-frame/aiu-registration`: free variables, docstring width, an obsolete `max-specpdl-size`, a duplicate `cyberdeck-insert`. Pre-existing, surfaced whenever that file recompiles. |

---

## 12. Quick reference

```sh
VAULT=/data/data/com.termux/files/home/Subnet
EMACS=$VAULT/universe/galaxy/solar-system/planets/earth/computer-science/operating-systems/linux/text-editors/neomacs/AIU Cyberdeck

# health, after a boot
grep -o ':status [a-z-]*' ~/.config/emacs/cyberdeck-emacs-errors.log.el | sort | uniq -c

# paren check — use this, not a boot
neomacs --batch -Q --load /tmp/kilo/bc.el "$EMACS/emacs-cyberdeck/<file>"

# duplicate MM_ORDER (should print nothing)
grep -oE ':MM_ORDER:[ \t]+[0-9.]+' -r $VAULT/universe/ | sort | uniq -d

# units the loader would discover
grep -rlE '^\* .*:EMACS_MECHANISM:' $VAULT/universe/ | wc -l

# Cyberdeck database
sqlite3 $VAULT/admin/cyberdeck.db 'select count(*) from notes;'

git -C $VAULT status --short
git -C $VAULT diff --stat
```

**`grep` gotcha that cost time twice:** in a *basic* regex, `\+` means "one or
more of the previous", not a literal `+`. `grep -c '^#\+begin_src'` silently
matches nothing, because the line is `#+begin_src`. Use `rg`, or `[+]`, or a
plain `+` in BRE.

## Warnings/errors: fix everything observed
- Fix every error/warning seen this session (boot, *Warnings*, byte-compile).
  Never defer, never silently suppress. Third-party causes need a durable
  in-scope workaround or an explicit user decision.
