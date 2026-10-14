# WIP — CONCEPT ONLY, DO NOT BUILD YET

This file is a parked concept. Nothing in it is approved for
implementation, and no code in any project may depend on it yet.
Work starts only after pm v1 is finished; until then it is read-only
context for future planning. Items that need the owner are listed in
section 10 and stay undecided until this project opens.

---

# System declaration: plan (AIU-PM, after the package manager)

Status: PLAN ONLY. Nothing here is built. It starts after pm v1 is finished.
It is separate from NodeShape and does not depend on it.

## 1. What it is

One declaration describes one machine. The tool turns it into a plan,
shows the plan, and applies it as a numbered generation that can be
rolled back. It reuses the pm engine: plan, lock, apply, journal,
generations, rollback, verbose output, --format json, never auto-apply.

## 2. In scope

1. System: machine name, locale, timezone, users and groups (name, uid,
   shell, home, groups, password HASH only, never plain text), managed
   files with owner, group and mode, symlinks, mounts (fstab entries),
   GRUB menu entries, and the package list (pm packages and versions).
2. Services as CONFIGURATION ONLY: "this service is enabled" means
   writing the unit file or symlink that the machine's existing init
   already understands. No service manager is written.
3. Containers and VMs: each one is described in the declaration and the
   tool GENERATES the files for an existing tool (Podman or Docker for
   containers, QEMU for VMs). It declares and generates; it runs nothing
   itself.
4. Kernel (optional, later): a description of which stock Linux kernel,
   its options and modules, used only to generate configuration.

## 3. Out of scope (decided)

- A new init or service manager.
- A user-environment layer (Guix Home style). Containers cover this.
- A new kernel, new boot chain, or hardware abstraction. The machine uses
  the stock Linux kernel and GRUB. Hardware support is the kernel's job.
- Anything that needs a daemon in v1.

## 4. The model

    declaration -> plan -> root tree + ownership manifest -> apply

- Declaration: data describing the machine (format decided later; the
  first version may be .rktd like specs; NodeShape can replace it).
- Plan: the list of changes against the current state, shown before
  anything is touched. Every item says what, why and how.
- Root tree: a complete generated directory of the files the machine
  should have (for example /etc/hostname, /etc/passwd lines, unit files).
- Ownership manifest: a list of path, owner, group, mode, type, and
  link target for every item in the root tree.
- Apply: writes the tree and manifest to the machine as a new
  generation, switches to it atomically, keeps the old one for rollback.

## 5. Scope and privilege

- User scope (exists, D-029): everything under the user's own roots.
- System scope: writes /etc and creates users, so it needs root.
- A small privileged helper does only the root work: create users,
  chown, mknod, mount, install the generation. It is narrow, takes the
  manifest as input, and speaks the same JSON interface. It may be
  written in Rust. It is not a daemon in v1.
- The privileged helper never decides anything; it only carries out a
  manifest the user already approved.

## 6. Safety rules (hard)

1. Never auto-apply. The plan is shown, a human confirms.
2. An AI may read plans and events freely. It can never apply without
   the human confirmation token.
3. Secrets: password hashes and keys never appear on screen, in logs, or
   in the AI feed. One redaction path (same as pm).
4. Apply is atomic per generation and rollback always works, including
   when apply fails halfway: a failed apply leaves the old generation
   active and the new one marked incomplete.
5. No timers, no polling (D-015). Every wait ends on an event.
6. Every operation narrates itself completely (verbose rule).
7. Unmanaged files are never deleted silently. The plan lists files in
   managed directories that the declaration does not mention; the user
   decides.
8. Locking: one writer, try-lock, fail fast. Readers never lock.

## 7. Planned modules (Racket, same style as pm)

    system/
      declaration.rkt   read and validate a declaration (pure)
      users.rkt         users and groups to manifest entries (pure)
      files.rkt         managed files, modes, symlinks (pure)
      mounts.rkt        fstab entries (pure)
      boot.rkt          GRUB entries and kernel options (pure)
      services.rkt      enabled services to unit files or symlinks (pure)
      containers.rkt    container declarations to Podman or Docker files
      vms.rkt           VM declarations to QEMU configuration
      tree.rkt          declaration to root tree + ownership manifest
      diff.rkt          current state versus tree: the plan
      generation.rkt    numbered generations, atomic switch, rollback
      apply.rkt         applies a generation (uses the privileged helper)
    helper/             the narrow privileged helper (maybe Rust)

Pure modules produce data. Only apply.rkt and the helper have effects.
The container and VM modules have one small output module per tool, so
adding the second tool later is a small change.

## 8. Testing

- Everything up to and including the root tree and the manifest is pure
  and is tested with synthetic declarations in a throwaway directory.
- Ownership and modes are verified on the phone with fakeroot and a
  state file (measured: ownership persists between runs).
- NOT testable on the phone (proot): real users, real chown to other
  uids, mknod, real mounts, GRUB, init and services, real containers,
  VMs (no KVM). These need a real machine or a VM.
- First real test: a spare VM or machine, with a snapshot taken first.
- See docs/PROOT-CAPABILITIES.org for the measured table.

## 9. Phases

S0  Declaration format: users, files, hostname only. Pure.
S1  tree.rkt and the manifest. Tested into a fake root with fakeroot.
S2  diff.rkt: plan against a fake "current" root.
S3  generation.rkt and rollback inside a fake root.
S4  Packages: the pm package list becomes part of the declaration.
S5  Mounts, GRUB entries, services as configuration.
S6  Privileged helper and system scope (needs a real machine or VM).
S7  First real apply on a throwaway machine, with a snapshot.
S8  Containers: Podman first or Docker first (open), generated files.
S9  VMs: QEMU configuration generated; run only on a real machine.
S10 Optional kernel description.

S0 to S5 are doable on the phone. S6 and later need a real machine.

## 10. Open decisions (owner)

1. Which init the target machines use. It decides what services.rkt
   generates. Default: whatever the machine already runs (systemd on
   Ubuntu); one output module per init.
2. Podman or Docker first. Default: Podman (rootless, no daemon).
3. Declaration format: .rktd first, NodeShape later. Default: .rktd.
4. Language of the privileged helper: Racket or Rust. Default: Rust,
   small, only after S5.
5. Does a declaration manage the whole machine or only listed paths?
   Default: only the paths it lists (unmanaged files are left alone).
6. How MappingOS relates: replaces the Guix base or sits on top.
   Default: undecided until S6.

## 11. Relation to other projects

- pm: the declaration's package list is resolved, locked and applied by
  the pm engine. The system declaration adds files, users and boot on
  top.
- NodeShape: a later way to write declarations. Nothing in this plan
  depends on it.
- Verbose and MCP feed: every plan and apply emits the same events, so
  an AI sees them live. State-changing tools need the confirmation token.

## 12. Definition of done (v1 of this project)

A declaration of a machine with users, files, mounts, GRUB entries and
a package list produces a plan, applies as a generation on a real
machine or VM, survives a deliberately failed apply with the old
generation intact, and rolls back. Containers and VMs: the declaration
generates the files and they run under Podman or QEMU on a real machine.
