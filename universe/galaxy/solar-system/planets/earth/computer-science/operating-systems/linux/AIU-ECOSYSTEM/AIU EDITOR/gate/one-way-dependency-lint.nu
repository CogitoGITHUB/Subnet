#!/usr/bin/env nu
# One job: the area table above, enforced — a require may point downward only.
# Registered in plan/package-tree.org; the area order is transcribed from
# plan/package-tree.org, "The law", and that file stays the source for it.
#
# errors is the floor and entry is the ceiling; a reference from a lower area
# to a higher one is a failure. This lint starts checking for real by itself as
# soon as areas exist — no edit to the dispatcher is needed.
#
# Style note: every count is bound to a name first, and no interpolation string
# carries a bare parenthesis. This phone's Nu parses both badly, and the rule
# is kept in one place by following it everywhere.

use ./env.nu *

const AREAS = ["errors" "narration" "machine" "security" "join" "devloop" "journal" "buffer" "notation" "commands" "routes" "input" "drawing" "models" "dashboard" "send" "picker" "checkpoint" "audit" "entry"]

# area_index answers the position of an area in the declared order, and 99 for
# a name the table does not hold.
def area_index [name] {
    $AREAS | enumerate | where {|a| $a.item == $name } | get -o item index | default 99
}

# main reads every require between areas, checks each points downward in the
# declared order, and exits non-zero when one points upward.
def main [] {
    let files = (glob $"($package_src)/**/*.rkt") | lines
    let file_count = ($files | length)

    if ($file_count == 0) {
        print "NOTHING-TO-CHECK one-way — no Racket files exist under editor/src yet"
        exit 0
    }

    # Only relative .rkt paths count: a require of a Racket library is not a
    # dependency between areas.
    let pairs = ($files | each {|p|
        let here = ($p | path relative-to $package_src | split row "/" | first)
        open --raw $p | lines | where {|l| ($l | str contains "require") } | each {|l|
            $l | str replace -a --regex '\.rkt"' '|' | split row "|" | skip 1
            | where {|q| ($q | str trim | str starts-with ".") } | each {|q|
                let target = ($q | str trim | split row "/" | last | str replace --regex '\.rkt$' '')
                {from: $here, to: $target}
            }
        }
    } | flatten)

    let pair_count = ($pairs | length)

    if ($pair_count == 0) {
        print $"NOTHING-TO-CHECK one-way — ($file_count) files scanned, none requires another area yet"
        exit 0
    }

    let bad = ($pairs | where {|e| (area_index $e.to) > (area_index $e.from) })
    let bad_count = ($bad | length)

    if ($bad_count == 0) {
        print $"OK one-way — ($pair_count) requires checked in ($file_count) files, all point downward"
        exit 0
    }

    for b in $bad {
        let from = $b.from
        let to = $b.to
        print $"ONE-WAY — from area ($from) to ($to); a require may only point downward"
    }
    print $"ONE-WAY — ($bad_count) upward requires in ($file_count) files"
    exit 1
}