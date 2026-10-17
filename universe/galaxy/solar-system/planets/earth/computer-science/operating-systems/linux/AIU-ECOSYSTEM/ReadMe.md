# AIU Ecosystem
AIU (Atomic Information Unit) minimal, self-contained unit of information with identity, structure, and enough context to stand alone and link into a larger system.

Standalone tools that share one design law: **nothing important is silent, nothing important is irreversible without a record, and AI is a first-class operator—not a bolt-on.**

Each project is its own repo, its own release cycle, and its own README. Use one tool or use all of them. The ecosystem is optional; the quality of each part is not.

## Components

| Component | Role | Status |
|-----------|------|--------|
| **Package manager** (`pm`) | Declarative install, plan/apply/rollback, full event narration, agent-safe MCP | In progress — engine real, commands coming online |
| **AIU-NOTATION** | Syntax + format engine for structured documents (Markdown-easy surface, deep structure, typesetting-capable). One plain-text notation, elements named in words; the engine stays behind a boundary | Planned |
| **AIU editor** | Text editor built for that structure, keyboard-driven workflow, and AI-readable session state | Planned |
| **AIU TM** | Terminal multiplexer with the same event discipline: sessions, panes, and jobs as structured runs | Planned |

## Design laws (shared)

- **Narration** — Operations explain what, why, how, when, and how long. Screen, log, and machine feed stay consistent.
- **Reversibility** — Applies are journalled; rollback and remove are first-class.
- **Agent boundaries** — AI can read freely; state-changing actions require explicit confirmation policy.
- **Standalone first** — No component requires the others to be useful.
- **Compatibility second** — Named bridges connect tools when you want a full workflow.

## Intended workflow (optional)

1. **pm** installs and records what the machine has.
2. **AIU-NOTATION** defines structured documents and specs.
3. **AIU editor** edits those documents and project code.
4. **AIU TM** hosts live processes with the same audit-friendly event model.

You can stop at step 1. Many users should.

## AI

The ecosystem treats AI as a primary operator:

- Structured event feeds (not only human logs)
- Tool surfaces (e.g. MCP) with clear read vs mutate rules
- Package definitions and clones assistable by AI under policy
- Same discipline across install, edit, and terminal sessions as components land

## Repos

| Project | Repository |
|---------|------------|
| Package manager | *link when public* |
| AIU-NOTATION | *link when public* |
| AIU editor | *link when public* |
| AIU TM | *link when public* |

Nothing is published as vapor. Each repo goes public when it works for its own stated scope.

## What this is not

- Not a forced monorepo
- Not a religion about replacing your entire stack on day one
- Not “AI does whatever” — mutate paths are constrained and logged

## License

*TBD per component.*

---

**Start here:** the package manager. It is the first fundamental and the one farthest along. Everything else builds on lessons proven there.

