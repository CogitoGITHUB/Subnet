#!/usr/bin/env nu
# scripts/check.nu -- green gate for CyberDeck (P-1, T-7).
#
# Converted from scripts/check.sh, one stage at a time. This file so far
# implements STAGE 6 ONLY: the text lint. check.sh remains the gate until
# the last stage lands, and is still expected to pass unchanged.
#
# Stage 6 rules, unchanged from check.sh lines 65-79:
#   - no tabs
#   - no trailing spaces
#   - no line over 102 characters (0.FOUNDATION.org is exempt: user contract)
#   - final newline required
# Now covering .nu files as well as .org, .rkt and .sh, because this file
# is one of the things being linted.

# Pinned Nushell (D-020). Change here and nowhere else.
const PINNED = "0.116.1"

# Exit codes: 0 clean, 1 violations found, 3 the running Nu is not pinned.
const EXIT_VIOLATIONS = 1
const EXIT_VERSION = 3

# The one file exempt from the line-length check.
const LENGTH_EXEMPT = "0.FOUNDATION.org"

# Longest allowed line, characters.
const MAX_LINE = 102

# -> string, current UTC instant, second precision
def utc [] {
    date now | format date "%Y-%m-%dT%H:%M:%SZ"
}

# -> string, version of the Nu running this script
def running-version [] {
    let exe = ($nu.current-exe)
    (do { run-external $exe "--version" } | complete).stdout | str trim
}

# Fails loudly when the running Nu is not the pinned one. Never fetches.
def require-pinned-version [] {
    let got = (running-version)
    if $got != $PINNED {
        print --stderr $"check: nu ($got) is running, but ($PINNED) is pinned"
        print --stderr $"check: refusing to run; install ($PINNED) by hand, scripts never fetch it"
        exit $EXIT_VERSION
    }
}

# -> list, lint targets under root: every .org, .rkt, .sh and .nu,
# compiled output excluded, sorted like the old `find | sort`.
def lint-files [root] {
    let pats = ["**/*.org" "**/*.rkt" "**/*.sh" "**/*.nu"]
    let found = ($pats | each {|p| glob $"($root)/($p)"} | flatten)
    # old find was `-type f`; a glob can also match a directory
    let files = ($found | where {|f| ($f | path type) == "file"})
    $files | where {|f| not ($f | str contains "/compiled/")} | sort
}

# -> list, 1-based line numbers of every line containing a tab
def tab-lines [ls] {
    $ls | enumerate | where {|r| ($r.item | str contains (char tab))} | get index | each {|i| $i + 1}
}

# -> list, 1-based line numbers of every line ending in a space
def space-lines [ls] {
    $ls | enumerate | where {|r| ($r.item | str ends-with " ")} | get index | each {|i| $i + 1}
}

# -> list, 1-based line numbers of every line over MAX_LINE characters
def long-lines [ls] {
    $ls | enumerate | where {|r| ($r.item | str length) > $MAX_LINE} | get index | each {|i| $i + 1}
}

# path -> list, one string per violation, "path:line:reason".
# Line 0 marks a whole-file property.
def lint-file [f] {
    let body = (open --raw $f)
    let ls = ($body | lines)
    let has_tab = ($body | str contains (char tab))
    let tabnums = (if $has_tab { tab-lines $ls } else { [] })
    let spacenums = (space-lines $ls)
    let longnums = (if (($f | path basename) != $LENGTH_EXEMPT) { long-lines $ls } else { [] })
    let has_nl = ($body | str ends-with (char newline))
    let nl = (if $has_nl { [] } else { [ $"($f):0:no final newline" ] })
    $tabnums | each {|n| $"($f):($n):tab"}
    | append ($spacenums | each {|n| $"($f):($n):trailing space"})
    | append ($longnums | each {|n| $"($f):($n):line over ($MAX_LINE) chars"})
    | append $nl
}

# path -> list, every violation under root, nothing printed
def lint-collect [root] {
    let files = (lint-files $root)
    $files | each {|f| lint-file $f} | flatten
}

# path -> nothing. Prints the violations and the summary for one root.
def lint-root [root] {
    let files = (lint-files $root)
    let all = ($files | each {|f| lint-file $f} | flatten)
    for v in $all {
        print $v
    }
    print $"lint: ($files | length) files, ($all | length) violations"
}

def run-stage-6-body [] {
    print $"[check] stage 6 text lint"
    # Roots come from $env, not from arguments: this Nu build exposes no
    # args column on $nu or $env, so a positional path is silently dropped
    # (verified 0.116.1). CYBERDECK_LINT_ROOTS is colon-separated and
    # makes the lint runnable against a fixture outside the repo.
    let spec = ($env | get -o CYBERDECK_LINT_ROOTS? | default ".")
    # split row, not split column: column yields a stream, and a stream
    # root breaks the glob pattern downstream
    let roots = ($spec | split row " ")
    # timeit cannot capture mutable variables (verified in 0.116.1) and
    # discards the closure value, so the timed block prints its own
    # output and calls exit itself.
    let total = (timeit {
        require-pinned-version
        for r in $roots {
            lint-root $r
        }
    })
    # timeit discards the closure value, so the exit code is derived by a
    # second collect pass. It costs a few ms and keeps the timed block to
    # the real work: one lint-and-report pass.
    let violations = ($roots | each {|r| lint-collect $r} | flatten | length)
    if $violations > 0 { exit $EXIT_VIOLATIONS }
}

# Stage 1 (check.sh lines 8-11): cli/ must never reference the test-only
# file-URL flag. The old stage used `grep -rq` over cli/; here the files
# are read directly and searched with str contains, no external grep.
def stage-1 [] {
    if not ("cli" | path exists) {
        return 0
    }
    let files = (glob "cli/**/*.rkt")
    let hits = ($files | where {|f|
        (open --raw $f) | str contains "current-allow-file-urls" })
    if ($hits | is-empty) {
        return 0
    }
    print "GATE: cli/ must never reference current-allow-file-urls"
    $hits | each {|h| print $"  offender: ($h)"}
    1
}

def run-stages [] {
    let want = ($env | get -o CYBERDECK_STAGES? | default "6")
    let todo = ($want | split row ",")
    let total = (timeit {
        require-pinned-version
        if "1" in $todo {
            print $"[check] stage 1 cli file-url flag"
            let rc = (stage-1)
            print $"[check] stage 1 exit=($rc)"
        }
        if "6" in $todo {
            run-stage-6-body
        }
    })
    print $"[check] end utc=(utc) after=(($total | into int))ns"
}

# NOT named main: nu auto-runs a command called main, so naming it main
# AND calling it explicitly runs the whole stage twice (verified 0.116.1).
run-stages

