#!/usr/bin/env nu
# One job: the naming law, made mechanical — no path in the package may carry
# a banned word. Registered in plan/package-tree.org.
#
# A stage with nothing to check prints NOTHING-TO-CHECK and never PASS.

use ./env.nu *

# The banned words are the ecosystem law's: no core/, engine/, utils/,
# manager/, handler/, tmp/ (plan/package-tree.org, "The law").
const BANNED = ["core" "engine" "utils" "manager" "handler" "tmp"]

# main scans every path under notation/ for a banned segment and prints each
# bad name; it prints NOTHING-TO-CHECK when no paths exist yet.
def main [] {
    let root = $project_root
    let scanned = (glob $"($root)/notation/**/*") | where {|p|
        let t = try { $p | path type } catch { "unknown" }
        $t in ["file" "dir"]
    }

    if ($scanned | is-empty) {
        print "NOTHING-TO-CHECK banned-words: no paths exist under notation/ yet"
        exit 0
    }

    let found = ($scanned | each {|p|
        let rel = $p | path relative-to $root
        $rel | split row "/" | enumerate | where {|seg| $seg.item in $BANNED } | each {|seg|
            {path: $rel, segment: $seg.item, line: 0}
        }
    } | flatten)

    let checked = $scanned | length
    if ($found | is-empty) {
        print $"OK banned-words: ($checked) paths checked, no banned word in any name"
        exit 0
    }

    for f in $found {
        print $"(BANNED-WORD) ($f.path) — the segment '($f.segment)' is banned; rename the path"
    }
    print $"BANNED-WORDS: ($found | length) bad names in ($checked) paths"
    exit 1
}