#!/bin/sh
# scripts/check.sh -- green gate for CyberDeck (P-1, T-7).
# raco make + raco test + text lint. Must print ALL GREEN before commit.
set -eu
cd "$(dirname "$0")/.."
RACO="$HOME/opt/racket/bin/raco"
fail=0
# cli/ must never reference the test-only file-URL flag (D-011).
if [ -d cli ] && grep -rq "current-allow-file-urls" cli/; then
  echo "GATE: cli/ must never reference current-allow-file-urls"; fail=1
fi
# The git backend tests need git.
if ! command -v git >/dev/null 2>&1; then
  echo "GATE: git executable not found"; fail=1
fi
# backends/run.rkt spawns through setsid/env and kills trees with pkill.
for tool in env setsid pkill; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "GATE: $tool executable not found (run.rkt needs it)"; fail=1
  fi
done
# Vault mirrors live in sources/ (D-011): gitignored, never tracked,
# never an embedded repo. Outer repo tracks specs/lockfile/manifest only.
if ! grep -qx "sources/" .gitignore 2>/dev/null; then
  echo "GATE: .gitignore must list sources/ (D-011)"; fail=1
fi
if git ls-files -- sources 2>/dev/null | grep -q .; then
  echo "GATE: sources/ must never be tracked"; fail=1
fi
if git ls-files -s -- sources 2>/dev/null | grep -q "^16"; then
  echo "GATE: sources/ must never embed a git repo"; fail=1
fi
# 1. Text lint: no tabs, no trailing spaces, no line over 102 characters,
# final newline. Applies to .org, .rkt and .sh files.
for f in $(find . -type f \( -name '*.org' -o -name '*.rkt' \
  -o -name '*.sh' \) -not -path './compiled/*' | sort); do
  if grep -q "$(printf '\t')" "$f"; then echo "TAB: $f"; fail=1; fi
  if grep -qn ' $' "$f"; then echo "TRAILING SPACE: $f"; fail=1; fi
  # 0.FOUNDATION.org is exempt from the length check (user's contract).
  if [ "$f" != "./0.FOUNDATION.org" ]; then
    if ! awk -v f="$f" 'length > 102 \
      {print "LONG LINE " FNR ": " f; bad=1} END {exit bad}' "$f"; then
      fail=1
    fi
  fi
  if [ -n "$(tail -c 1 "$f")" ]; then echo "NO FINAL NEWLINE: $f"; fail=1; fi
done
# 2. Compile every .rkt file.
rkts=$(find . -type f -name '*.rkt' -not -path './compiled/*' | sort)
if [ -n "$rkts" ]; then
  # shellcheck disable=SC2086
  "$RACO" make -v $rkts || fail=1
fi
# 3. Run the tests in every .rkt file.
if [ -n "$rkts" ]; then
  # shellcheck disable=SC2086
  "$RACO" test $rkts || fail=1
fi
if [ "$fail" -eq 0 ]; then
  echo "ALL GREEN"
else
  echo "CHECK FAILED"
fi
exit "$fail"
