---
name: guix
description: Use when the user asks about Guix, Guix System, Guix Home, package management, guix shell, operating system configuration, services, or any Guix-related task. The user runs Guix System.
---

# Guix

## Package management

- `guix install <pkg>` — install a package in profile
- `guix remove <pkg>` — remove
- `guix upgrade` — upgrade all
- `guix search <term>` — search packages
- `guix show <pkg>` — show details
- `guix gc` — garbage collect

## Guix shell

- `guix shell <pkg>` — temporary environment
- `guix shell <pkg> -- <cmd>` — run command in ephemeral env
- `guix shell -D <pkg>` — development environment
- `guix shell -D -f guix.scm` — from manifest file

## System configuration

System config: `/etc/config.scm` (referenced by the guix-home config at `/home/aoeu/guix-home-config.scm`)

- `guix system reconfigure /etc/config.scm` — apply system changes
- `guix system search <service>` — find service types
- `guix system roll-back` — revert to previous generation

## Guix Home

Home config: `/home/aoeu/guix-home-config.scm`

- `guix home reconfigure ~/guix-home-config.scm` — apply home changes
- `guix home roll-back` — revert

## Generations

- `guix pull` — update Guix itself
- `guix describe` — show current Guix revision
- `guix time-machine --commit=<rev> -- <cmd>` — run with old Guix

## Channels

Channels file: `~/.config/guix/channels.scm`

- Add `nonguix` channel for non-free software
- `guix pull --channels=~/my-channels.scm` — use custom channels
