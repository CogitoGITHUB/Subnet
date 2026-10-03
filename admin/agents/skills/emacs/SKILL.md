---
name: emacs
description: Use when the user asks about Emacs, org-mode, Elisp, Emacs configuration, keybindings, packages, or any Emacs-related task. Covers editing, customization, and ecosystem.
---

# Emacs

## Keybindings

- `C-x C-f` — find file
- `C-x C-s` — save
- `C-x b` — switch buffer
- `C-x C-b` — list buffers
- `C-s` — search forward
- `C-r` — search backward
- `M-%` — query replace
- `C-x 3` — split right
- `C-x 2` — split below
- `C-x 0` — close current window
- `C-x o` — switch to other window
- `M-x` — execute command

## Org-mode

- `C-c C-t` — TODO/DONE cycle
- `C-c C-c` — toggle checkbox / execute src block
- `C-c C-n/p` — next/previous heading
- `C-c ^` — sort entries
- `C-c C-x C-i` — clock in
- `C-c C-x C-o` — clock out
- `#+BEGIN_SRC lang` / `#+END_SRC` — source blocks
- `C-c '` — edit source block in separate buffer

## Configuration

- `~/.config/emacs/init.el` (canonical location; `~/.emacs.d` → `~/.config/emacs`)
- Use `use-package` for declarative package config
- `M-x eval-buffer` to reload config
- `M-x package-install` to install packages

## Elisp basics

- `(setq var value)` — set variable
- `(defun name (args) ...)` — define function
- `(mapcar fn list)` — apply function to each element
- `(lambda (x) ...)` — anonymous function
