#!/usr/bin/env nu
# One job: the area table above, enforced — a require may point downward only.
# Registered in plan/package-tree.org; the area order is transcribed from
# plan/package-tree.org, "The law", and that file stays the source for it.
#
# errors is the floor and entry is the ceiling; a reference from a lower area
# to a higher one is a failure. This lint starts checking for real by itself as
# soon as areas exist — no edit to the dispatcher is needed.
#
# What it reads: every require form in every Racket file, taken whole, because
# a require form may span lines and the path lives on its own line. Each path
# that starts with a dot is resolved against the directory of the file that
# holds the require, and the area it names is the first segment of the
# resolved path inside the package. A path that leaves the package is a
# failure too: the package holds everything it needs.
#
# Style note: every count is bound to a name first, and no interpolation string
# carries a bare parenthesis. This phone's Nu parses both badly, and the rule
# is kept in one place by following it everywhere.

use ./env.nu *

# The areas, lowest first, transcribed from plan/package-tree.org: a require
# may only point downward through this order.
const AREAS = ["errors" "narration" "machine" "security" "join" "devloop" "journal" "buffer" "notation" "commands" "routes" "input" "drawing" "models" "dashboard" "send" "picker" "checkpoint" "audit" "entry"]

# area_index answers the position of an area in the declared order, and 99 for
# a name the table does not hold.
def area_index [name] {
    let found = ($AREAS | enumerate | where {|a| $a.item == $name })
    if ($found | is-empty) { 99 } else { $found | first | get index }
}

# clean-text answers the code of one file with the comments taken out, so a
# require that only a comment mentions is not counted as a dependency. A line
# that starts with a semicolon is a comment of its own; the rest keep the
# code in front of their comment.
def clean-text [text] {
    let no_blocks = ($text | str replace --all --regex '(?s)#\|.*?\|#' ' ')
    $no_blocks | lines | each {|line|
        let trimmed = ($line | str trim)
        if ($trimmed | str starts-with ";") {
            null
        } else {
            $line | str replace --regex ';;.*$' ''
        }
    } | where {|l| $l != null }
}

# require-paths answers the file paths one file requires. The code is
# flattened into one line first, so a require form that spans lines is read
# whole. Only a path that names a Racket file counts: a library name is not a
# dependency between areas.
def require-paths [text] {
    let flat = ($text | str join " ")
    let forms = (try { $flat | parse --regex '(?s)\(require((?:[^()]|\([^()]*\))*)\)' | get -o capture0 } catch {|e| [] })
    $forms | each {|form|
        let paths = (try { $form | parse --regex '"([^"]+)"' | get -o capture0 } catch {|e| [] })
        $paths | where {|p| ($p | str ends-with ".rkt") }
    } | flatten
}

# area-of answers the area a file belongs to: the first segment of its path
# inside the package.
def area-of [file] {
    let rel = ($file | path relative-to $package_src)
    $rel | split row "/" | first
}

# target-area answers the area a required path names, resolved against the
# directory of the file that requires it. It answers nothing when the path
# leaves the package, and the caller treats that as a failure.
def target-area [file required] {
    let dir = ($file | path dirname)
    let absolute = ($dir | path join $required | path expand)
    let rel = (try { $absolute | path relative-to $package_src } catch {|e| null })
    if ($rel == null) { null } else { $rel | split row "/" | first }
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

    # Every require path, with the area that holds it, the area it names and
    # whether it points upward.
    let pairs = ($files | each {|p|
        let from = (area-of $p)
        let paths = (require-paths (clean-text (open --raw $p)))
        $paths | each {|q|
            let to = (target-area $p $q)
            let up = (if ($to == null) { true } else { (area_index $to) > (area_index $from) })
            {from: $from, to: $to, path: $q, file: $p, up: $up}
        }
    } | flatten)

    let pair_count = ($pairs | length)

    if ($pair_count == 0) {
        print $"NOTHING-TO-CHECK one-way — ($file_count) files scanned, none requires another area yet"
        exit 0
    }

    let bad = ($pairs | where {|e| $e.up })
    let bad_count = ($bad | length)

    if ($bad_count == 0) {
        print $"OK one-way — ($pair_count) requires checked in ($file_count) files, all point downward"
        exit 0
    }

    for b in $bad {
        let rel = ($b.file | path relative-to $package_src)
        let from = $b.from
        let to = (if ($b.to == null) { "outside the package" } else { $b.to })
        let path = $b.path
        print $"ONE-WAY — ($rel) requires ($path); from area ($from) to ($to); a require may only point downward"
    }
    print $"ONE-WAY — ($bad_count) upward requires in ($file_count) files"
    exit 1
}
