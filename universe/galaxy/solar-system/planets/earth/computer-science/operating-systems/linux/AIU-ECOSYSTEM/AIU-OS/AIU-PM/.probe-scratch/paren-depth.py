#!/usr/bin/env python3
"""paren-depth.py FILE [FROM] [TO] -- net paren depth per line.

Racket-aware: skips ; comments, "..." strings (with backslash escapes),
and #[...] bracket pairs, and reports where depth returns to 0.
"""
import sys

path = sys.argv[1]
lo = int(sys.argv[2]) if len(sys.argv) > 2 else 1
hi = int(sys.argv[3]) if len(sys.argv) > 3 else 10**9

depth = 0
in_str = False
in_comment = False
prev_top = None

with open(path, encoding="utf-8") as fh:
    for n, line in enumerate(fh, 1):
        start_depth = depth
        i = 0
        while i < len(line):
            c = line[i]
            if in_comment:
                break
            if in_str:
                if c == "\\":
                    i += 2
                    continue
                if c == '"':
                    in_str = False
                i += 1
                continue
            if c == ";":
                in_comment = True
                break
            if c == '"':
                in_str = True
                i += 1
                continue
            if c == "#" and i + 1 < len(line) and line[i + 1] in "[{":
                depth += 1
                i += 2
                continue
            if c in ")]}":
                depth -= 1
            elif c in "([{":
                depth += 1
            i += 1
        in_comment = False
        if lo <= n <= hi:
            marker = ""
            if start_depth == 0 and depth > 0 and prev_top is None:
                marker = "  <-- TOP-LEVEL FORM STARTS"
                prev_top = n
            if start_depth == 0 and depth == 0:
                marker = "  <-- FORM ENDS"
                prev_top = None
            print(f"{n:5d} depth {start_depth:3d}->{depth:3d}{marker}")
        if depth < 0:
            print(f"{n:5d} DEPTH WENT NEGATIVE")
            break

print(f"final depth: {depth}")
