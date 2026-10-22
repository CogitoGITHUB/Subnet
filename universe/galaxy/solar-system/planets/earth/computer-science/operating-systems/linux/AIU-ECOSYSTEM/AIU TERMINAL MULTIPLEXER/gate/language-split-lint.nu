#!/usr/bin/env nu
# One job: only join/ may cross Rust and Racket.
# Registered in multiplexer/INDEX.org.
#
# It checks every .rs and every .rkt file in the package for a reference to the
# other language. A reference outside join/ is a failure; join/ is where the
# crossing is allowed to live. It starts checking for real as soon as Rust
# files exist — no edit to the dispatcher is needed.
#
# Style note: no bare parenthesis inside an interpolation string and no "not";
# this phone's Nu parses both badly, so membership is tested positively.

use ./env.nu *

# in_join says whether a path lies under join/, the one area where a Rust file
# may name Racket and the reverse.
def in_join [p] {
    ($p | path relative-to $project_root) =~ "join/"
}

# rust_crossings returns each Rust file that names a .rkt file outside join/,
# one record per offender.
def rust_crossings [rs] {
    $rs | each {|p|
        let text = open --raw $p
        if ($text | str contains ".rkt") {
            if (in_join $p) { null } else { {path: $p, why: "a Rust file names a .rkt file"} }
        } else { null }
    } | where {|e| $e != null }
}

# racket_crossings returns each Racket file that names a .rs file, one record
# per offender.
def racket_crossings [rkt] {
    $rkt | each {|p|
        let text = open --raw $p
        if ($text | str contains ".rs") {
            if (in_join $p) { null } else { {path: $p, why: "a Racket file names a .rs file"} }
        } else { null }
    } | where {|e| $e != null }
}

# main checks every .rs and .rkt file for a reference to the other language
# outside join/ and exits non-zero when any such crossing exists.
def main [] {
    let rs = (glob $"($package_dir)/**/*.rs") | lines
    let rkt = (glob $"($package_dir)/**/*.rkt") | lines
    let checked = ($rs | length) + ($rkt | length)

    if ($checked == 0) {
        print "NOTHING-TO-CHECK language-split — no source files exist under multiplexer/ yet"
        exit 0
    }

    let bad = (rust_crossings $rs | append (racket_crossings $rkt))
    let bad_count = ($bad | length)

    if ($bad_count == 0) {
        let what = $"($checked) files checked, no Rust/Racket crossing outside join/"
        print $"OK language-split — ($what)"
        exit 0
    }

    for b in $bad {
        let rel = ($b.path | path relative-to $project_root)
        let why = $b.why
        print $"LANGUAGE-SPLIT — ($rel): ($why); only join/ may cross"
    }
    print $"LANGUAGE-SPLIT — ($bad_count) crossings outside join/ in ($checked) files"
    exit 1
}
