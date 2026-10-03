---
name: git
description: Use when the user asks about git, version control, GitHub, commits, branches, rebasing, merging, PRs, or any git workflow. Covers git commands, conventions, and patterns used in this project.
---

# Git

## Commit conventions

Use conventional commits: `type(scope): description`

Types: `feat`, `fix`, `chore`, `refactor`, `docs`, `style`, `test`, `perf`

## Branching

- `main` — stable, production-ready
- `feat/<name>` — new features
- `fix/<name>` — bug fixes
- `chore/<name>` — maintenance

## Workflow

1. `git pull --rebase` before starting work
2. Create a feature branch from `main`
3. Make small, atomic commits
4. `git rebase -i main` to clean up history before PR
5. Open PR with a clear description

## Useful commands

- `git log --oneline --graph --all` — visualize history
- `git diff --cached` — review staged changes
- `git commit --amend` — fix last commit (don't amend pushed commits)
- `git rebase -i HEAD~n` — squash/reword last n commits
- `git stash push -m "message"` — stash with name
