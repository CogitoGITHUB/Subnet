#!/bin/sh
# scripts/startup.sh -- measure Racket startup N times, print medians.
# Measurement only; changes nothing about startup. N defaults to 5.
# This dash has no `time` keyword, so per-run user/sys come from the
# children line of `times` (before/after deltas) and wall time from
# `date +%s%N`. The date helpers add ~2ms inside the window; the method
# is stable run to run, which is what baselines need.
set -eu
N="${1:-5}"
RACKET="$HOME/opt/racket/bin/racket"
if [ ! -x "$RACKET" ]; then
  echo "startup.sh: racket not found at $RACKET" >&2
  exit 2
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
"$RACKET" -l racket/base -e '(void)' >/dev/null 2>&1
i=1
while [ "$i" -le "$N" ]; do
  times > "$tmp/before$i"
  start=$(date +%s%N)
  "$RACKET" -l racket/base -e '(void)' >/dev/null 2>&1
  end=$(date +%s%N)
  times > "$tmp/after$i"
  echo "$start $end" > "$tmp/wall$i"
  i=$((i + 1))
done
i=1
while [ "$i" -le "$N" ]; do
  b=$(awk 'NR==2' "$tmp/before$i"); a=$(awk 'NR==2' "$tmp/after$i"); w=$(cat "$tmp/wall$i")
  set -- $b; bb1=$1; bb2=$2
  set -- $a; aa1=$1; aa2=$2
  set -- $w; ws=$1; we=$2
  awk -v b1="$bb1" -v b2="$bb2" -v a1="$aa1" -v a2="$aa2" \
    -v ws="$ws" -v we="$we" \
    'function secs(t,   a, s) { split(t, a, "m"); s = a[2]; sub(/s$/, "", s); return a[1] * 60 + s }
     BEGIN { printf "%.2f %.2f %.2f\n", (we - ws) / 1000000000, \
       secs(a1) - secs(b1), secs(a2) - secs(b2) }' \
    >> "$tmp/deltas"
  i=$((i + 1))
done
median_of() {
  sort -n "$1" | sed -n "$((N / 2 + 1))p"
}
awk '{ print $1 }' "$tmp/deltas" > "$tmp/c-real"
awk '{ print $2 }' "$tmp/deltas" > "$tmp/c-user"
awk '{ print $3 }' "$tmp/deltas" > "$tmp/c-sys"
echo "| run | real | user | sys |"
i=1
while [ "$i" -le "$N" ]; do
  r=$(sed -n "${i}p" "$tmp/c-real"); u=$(sed -n "${i}p" "$tmp/c-user")
  s=$(sed -n "${i}p" "$tmp/c-sys")
  echo "| $i | $r | $u | $s |"
  i=$((i + 1))
done
mr=$(median_of "$tmp/c-real"); mu=$(median_of "$tmp/c-user")
ms=$(median_of "$tmp/c-sys")
echo "| median | $mr | $mu | $ms |"
