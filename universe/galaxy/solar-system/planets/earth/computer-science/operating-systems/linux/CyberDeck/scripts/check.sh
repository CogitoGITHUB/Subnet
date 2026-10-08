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
# backends/run.rkt spawns through setsid/env, kills trees with pkill,
# and holds child locks with flock.
for tool in env setsid pkill flock mkfifo; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "GATE: $tool executable not found (run.rkt needs it)"; fail=1
  fi
done
# Vault monorepo (D-011 ruling): sources/vault.git holds all package
# objects and is NEVER tracked by the outer repo. Specs, lockfile and
# the manifest are tracked; the vault is not.
if ! grep -qx "sources/vault.git/" .gitignore 2>/dev/null; then
  echo "GATE: .gitignore must list sources/vault.git/ (D-011 monorepo)"; fail=1
fi
if grep -qx "sources/" .gitignore 2>/dev/null; then
  echo "GATE: .gitignore must not blanket-list sources/ (specs live there)"; fail=1
fi
if git ls-files -- sources/vault.git 2>/dev/null | grep -q .; then
  echo "GATE: sources/vault.git must never be tracked"; fail=1
fi
if git ls-files -s -- sources 2>/dev/null | grep -q "^16"; then
  echo "GATE: sources/ must never embed a git repo (use the monorepo)"; fail=1
fi
# 0. TUI rebrand gates: no Guix coupling, no graph/mind-map remnants.
# (the one exception is the serde compat alias in tui/src/model.rs).
if [ -d tui ]; then
  if grep -rni "guix" tui/src tui/web tui/tests tui/README.md \
    tui/README.pt-BR.md tui/Cargo.toml 2>/dev/null \
    | grep -v 'alias = "guix_commit"' | grep -q .; then
    echo "GATE: tui/ must not reference guix (see alias exception)"; fail=1
  fi
  if grep -rnE "GraphView|crate::graph|ui/graph|web/graph|GraphParams" \
    tui/src tui/web tui/tests tui/README.md tui/README.pt-BR.md \
    tui/Cargo.toml 2>/dev/null; then
    echo "GATE: tui/ still references the removed graph"; fail=1
  fi
  if grep -rnE "graph_depth|graph_dirty|graph_follow|ensure_graph" \
    tui/src tui/web tui/tests 2>/dev/null; then
    echo "GATE: tui/ still references removed graph state"; fail=1
  fi
  if grep -rnE "select_delta|force-directed|module_neighbors|by_module" \
    tui/src tui/web tui/tests tui/README.md tui/README.pt-BR.md \
    2>/dev/null; then
    echo "GATE: tui/ still references removed graph model"; fail=1
  fi
  if grep -rnE "DEFAULT_DEPTH|NODE_BUDGET|clamp_depth|GRAPH_JS|graph\.js" \
    tui/src tui/web tui/tests 2>/dev/null; then
    echo "GATE: tui/ still references removed graph budget"; fail=1
  fi
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
# 0b. Git transport allowlist for every test spawn below: file only.
export GIT_ALLOW_PROTOCOL=file

# Fast set: no subprocesses (in-process only). Slow files spawn and
# run detached before each commit instead (see TEST-START lines).
FAST_RKTS="core/errors.rkt core/git-id.rkt core/git-url.rkt core/version.rkt
core/spec.rkt core/spec-read.rkt core/resolve.rkt core/plan.rkt core/ui.rkt
core/log.rkt core/lock.rkt core/cancel.rkt cli/main.rkt info.rkt
backends/dry-run.rkt backends/fake.rkt"

now_ms() { date +%s%N | cut -c1-13; }

mode="full"
if [ "${1:-}" = "--fast" ]; then mode="fast"; fi
# 2. Compile every .rkt file.
rkts=$(find . -type f -name '*.rkt' -not -path './compiled/*' | sort)
step_start=$(now_ms)
if [ -n "$rkts" ]; then
  # shellcheck disable=SC2086
  "$RACO" make -v $rkts || fail=1
fi
echo "STEP-END compile after=$(( $(now_ms) - step_start ))ms"
# 3. Run the tests file by file: TEST-START/END per file with durations,
# so a hang shows exactly which file and (via pm-run lines) which command.
if [ "$mode" = "fast" ]; then rkts="$FAST_RKTS"; fi
times=$(mktemp)
trap 'rm -f "$times"' EXIT
if [ -n "$rkts" ]; then
  # shellcheck disable=SC2086
  for f in $rkts; do
    s=$(now_ms)
    echo "TEST-START $f"
    if "$RACO" test "$f"; then st=0; else st=1; fail=1; fi
    e=$(now_ms)
    echo "TEST-END $f exit=$st after=$((e - s))ms"
    echo "$((e - s)) $f" >> "$times"
  done
fi
echo "SLOWEST:"
sort -rn "$times" | head -n 10
rm -f "$times"
trap - EXIT
if [ "$fail" -eq 0 ]; then
  if [ "$mode" = "fast" ]; then echo "FAST GREEN (partial)"; else echo "ALL GREEN"; fi
else
  echo "CHECK FAILED"
fi
exit "$fail"
