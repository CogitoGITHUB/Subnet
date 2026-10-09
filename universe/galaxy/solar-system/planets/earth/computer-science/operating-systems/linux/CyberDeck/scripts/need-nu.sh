#!/bin/sh
# scripts/need-nu.sh -- report which Nushell project scripts would use.
# Manual version control only (D-020 amended): this script never
# downloads, installs or updates anything. It prefers the newest
# ~/opt/nushell/*/nu, else falls back to PATH, else fails clearly.
# Usage: eval "$(sh scripts/need-nu.sh)" or just run it to see.
set -eu
best=""
for d in "$HOME"/opt/nushell/*/; do
  if [ -x "${d}nu" ]; then
    if [ -z "$best" ] || [ "$d" \> "$best" ]; then best="${d}nu"; fi
  fi
done
if [ -z "$best" ]; then
  if command -v nu >/dev/null 2>&1; then
    best="nu"
  else
    echo "need-nu: no nushell found (~/opt/nushell/*/nu, then PATH)" >&2
    echo "need-nu: install one by hand; scripts never fetch it" >&2
    exit 2
  fi
fi
ver=$("$best" --version 2>/dev/null || echo "version unknown")
echo "nu: $best ($ver)"
