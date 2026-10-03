---
name: neomacsclient
description: Use when the user asks about Neomacs integration, elisp evaluation, buffer management, or when opencode should interact with a running Neomacs session via neomacsclient. Also use when the emacs-mcp-server is unavailable.
---

# Neomacsclient

The user runs Neomacs. Connect with `neomacsclient` (socket via `-s` if the server uses a non-default one).

## Basic usage

```bash
neomacsclient --eval '(buffer-list)'
neomacsclient --eval '(with-current-buffer (find-file-noselect "~/test/foo.org") (buffer-string))'
```

## Useful snippets

- `(frame-root-window)` — get current window
- `(buffer-name)` — current buffer name
- `(buffer-string)` — contents of current buffer
- `(with-current-buffer "foo.org" (buffer-string))` — read specific buffer
- `(projectile-project-root)` — get project root
- `(my/notes-directory)` — get user's notes directory (`~/test/`)
- `(org-agenda-list)` — show agenda
- `(next-error)` — jump to next flycheck error
- `(compile "make test")` — run compilation
