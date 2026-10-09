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

# Stage 2 (check.sh lines 12-15): git must exist. `command -v` becomes
# `which`, a Nu built-in; only the exit status matters, as in the old gate.
def stage-2 [] {
    let w = (do { ^which git } | complete)
    if $w.exit_code != 0 {
        print "GATE: git executable not found"
        return 1
    }
    0
}

# Stage 3 (check.sh lines 16-22): the helper tools run.rkt shells out to.
# Existence only, as in the old gate. which is a Nu built-in; nothing is
# executed, nothing is installed.
def stage-3 [] {
    let tools = ["env" "setsid" "pkill" "flock" "mkfifo" "tar"]
    let missing = ($tools | where {|t| (do { ^which $t } | complete).exit_code != 0 })
    if ($missing | is-empty) {
        return 0
    }
    for t in $missing {
        print $"GATE: ($t) executable not found (run.rkt needs it)"
    }
    1
}

# Stage 4 (check.sh lines 23-37): the D-011 monorepo rules.
# `grep -qx` is a whole-line exact match, so the Nu side compares the
# stripped line to the exact string rather than using str contains.
# git ls-files has no Nu built-in equivalent; it is run as an external
# through run-external, which is the Nu way to call it.
def git-lines [args] {
    let r = (do { run-external "git" ...$args } | complete)
    if $r.exit_code != 0 {
        return []
    }
    $r.stdout | lines | where {|l| (($l | str trim) | is-not-empty)}
}

def stage-4 [] {
    # local to this function, never captured by a closure
    mut bad = 0
    let gi = (if (".gitignore" | path exists) {
        (open --raw ".gitignore") | lines | each {|l| $l | str trim}
    } else { [] })
    if not ("sources/vault.git/" in $gi) {
        print "GATE: .gitignore must list sources/vault.git/ (D-011 monorepo)"
        $bad = 1
    }
    if "sources/" in $gi {
        print "GATE: .gitignore must not blanket-list sources/ (specs live there)"
        $bad = 1
    }
    let tracked_vault = (git-lines ["ls-files" "--" "sources/vault.git"])
    if ($tracked_vault | is-not-empty) {
        print "GATE: sources/vault.git must never be tracked"
        $bad = 1
    }
    # gitlinks show up as mode 160000 in ls-files -s; "^16" catches them
    let modes = (git-lines ["ls-files" "-s" "--" "sources"]
                 | where {|l| ($l | str starts-with "16")})
    if ($modes | is-not-empty) {
        print "GATE: sources/ must never embed a git repo (use the monorepo)"
        $bad = 1
    }
    $bad
}

# Stage 5 (check.sh lines 38-64): the TUI rebrand gates. Five regexes,
# copied verbatim from check.sh. Nu's `=~` is compared against `grep -E`
# line by line in the fixtures and agrees on all of them, including the
# escaped dot in graph\.js (the line "graphXjs" must not match).
# Single-quoted regex strings only: "graph\.js" is an invalid escape
# inside a Nu double-quoted string.
def stage-5 [] {
    if not ("tui" | path exists) {
        return 0
    }
    let targets = ["tui/src" "tui/web" "tui/tests" "tui/README.md"
                   "tui/README.pt-BR.md" "tui/Cargo.toml"]
    let pats = ['GraphView|crate::graph|ui/graph|web/graph|GraphParams'
               'graph_depth|graph_dirty|graph_follow|ensure_graph'
               'select_delta|force-directed|module_neighbors|by_module'
               'DEFAULT_DEPTH|NODE_BUDGET|clamp_depth|GRAPH_JS|graph\.js']
    let msgs = ["GATE: tui/ still references the removed graph"
                "GATE: tui/ still references removed graph state"
                "GATE: tui/ still references removed graph model"
                "GATE: tui/ still references removed graph budget"]
    # grep -r recurses; open --raw does not, so directories are expanded
    # to their files first. Same bytes, same order-insensitive test.
    let allfiles = ($targets | each {|t|
        if not ($t | path exists) {
            []
        } else if ($t | path type) == "dir" {
            glob $"($t)/**/*" | where {|f| ($f | path type) == "file"}
        } else {
            [$t]
        } } | flatten)
    mut bad = 0
    mut i = 0
    for p in $pats {
        let hit = ($allfiles | any {|f| (open --raw $f | lines) | any {|l| $l =~ $p } })
        if $hit {
            print $"($msgs | get $i)"
            $bad = 1
        }
        $i = ($i + 1)
    }
    let guix_hit = ($allfiles | any {|f|
        (open --raw $f | lines) | any {|l|
            ($l =~ 'guix') and not ($l =~ 'alias = "guix_commit"') } })
    if $guix_hit {
        print "GATE: tui/ must not reference guix (see alias exception)"
        $bad = 1
    }
    $bad
}

# Stage 7 (check.sh lines 80-84): export GIT_ALLOW_PROTOCOL=file for every
# spawn below, then report which Nushell the scripts would use. The report
# is informational only: `|| true` in the old gate, so a non-zero exit here
# is recorded and swallowed rather than failing the gate.
def stage-7 [] {
    $env.GIT_ALLOW_PROTOCOL = "file"
    let nu_bin = ($env | get -o CYBERDECK_NU? | default ($nu.current-exe))
    let r = (do { run-external $nu_bin "--no-config-file" "scripts/need-nu.nu" } | complete)
    print $"[stage7] GIT_ALLOW_PROTOCOL=(($env | get GIT_ALLOW_PROTOCOL))"
    print $"[stage7] nu report exit=($r.exit_code)"
    for l in ($r.stdout | lines) {
        print $"[stage7] ($l)"
    }
    for l in ($r.stderr | lines) {
        print $"[stage7] stderr: ($l)"
    }
    0
}

# Stage 8 (check.sh lines 86-96): the fast set and --fast selection.
# Copied exactly from check.sh, in the same order. Timing is monotonic
# from timeit, so no `date +%s%N` and no `cut`.
const FAST_RKTS = [
  "core/errors.rkt" "core/git-id.rkt" "core/git-url.rkt" "core/version.rkt"
  "core/spec.rkt" "core/spec-read.rkt" "core/resolve.rkt" "core/plan.rkt" "core/ui.rkt"
  "core/log.rkt" "core/lock.rkt" "core/cancel.rkt" "cli/main.rkt" "info.rkt"
  "backends/dry-run.rkt" "backends/fake.rkt"
]

# -> list, the stage-8 file list for the current mode
def stage-8-files [fast] {
    if $fast {
        $FAST_RKTS
    } else {
        glob "**/*.rkt" | where {|f| not ($f | str contains "/compiled/")} | sort
    }
}

# Named main with a real --fast flag, so the CLI matches check.sh exactly
# (`nu scripts/check.nu --fast`). Verified 0.116.1: nu auto-invokes a
# command called main and passes the flag through; it must therefore NOT
# also be called explicitly, or the whole gate runs twice.
def main [--fast] {
    let want = ($env | get -o CYBERDECK_STAGES? | default "6")
    let todo = ($want | split row ",")
    let total = (timeit {
        require-pinned-version
        if "1" in $todo {
            print $"[check] stage 1 cli file-url flag"
            let rc = (stage-1)
            print $"[check] stage 1 exit=($rc)"
        }
        if "2" in $todo {
            print $"[check] stage 2 git present"
            let rc = (stage-2)
            print $"[check] stage 2 exit=($rc)"
        }
        if "3" in $todo {
            print $"[check] stage 3 helper tools present"
            let rc = (stage-3)
            print $"[check] stage 3 exit=($rc)"
        }
        if "4" in $todo {
            print $"[check] stage 4 D-011 monorepo rules"
            let rc = (stage-4)
            print $"[check] stage 4 exit=($rc)"
        }
        if "5" in $todo {
            print $"[check] stage 5 tui rebrand gates"
            let rc = (stage-5)
            print $"[check] stage 5 exit=($rc)"
        }
        if "7" in $todo {
            let rc = (stage-7)
            print $"[check] stage 7 exit=($rc)"
        }
        if "8" in $todo {
            let fs = (stage-8-files $fast)
            print $"[check] stage 8 file set ($fs | length) files fast=($fast)"
            for f in $fs { print $"[check] stage 8 file ($f)" }
        }
        if "6" in $todo {
            run-stage-6-body
        }
    })
    print $"[check] end utc=(utc) after=(($total | into int))ns"
}

# Stage 9-11 helpers (check.sh lines 97-130). Stages 1-8 stay above; these
# are the compile, test and verdict halves, proved on fixtures first.
#
# -> string, the raco check.sh uses (line 6), overridable for fixtures.
def raco-exe [] {
    $env | get -o CYBERDECK_RACO? | default ($nu.home-dir | path join "opt" "racket" "bin" "raco")
}

# -> string, the gate log directory, created on demand. Child output goes
# here, never into the tree; same XDG rule as scripts/env.nu.
def gate-log-dir [] {
    let base = ($env | get -o XDG_CACHE_HOME? | default ($nu.home-dir | path join ".cache"))
    let d = ($base | path join "cyberdeck" "gate")
    mkdir $d
    $d
}

# file, tag -> string, log path for one source file. "/" becomes "_", and
# the ".tag.log" tail is glued onto the name in one piece: path join with a
# separate ".log" argument yields "name/.log" instead (verified 0.116.1).
# The tag keeps the make log and the test log of one file apart.
def log-path [f tag] {
    (gate-log-dir) | path join (($f | str replace -a "/" "_") + "." + $tag + ".log")
}

# file -> record {file, exit, ms}
#
# TEST-START is printed before the child and TEST-END only after the child
# has exited, so a START without an END still means "stuck". D-015: no
# timer, no timeout, no sleep; the wait ends on process exit only.
#
# timeit returns a duration and discards the closure value, and a closure
# may not capture a mutable (that is a parse error in 0.116.1), so the
# child's complete record is written inside the timed block and read back
# from disk afterwards. ns -> ms is integer division of the duration.
def run-child [f] {
    let raco = (raco-exe)
    let lp = (log-path $f "test")
    let rp = ($lp | str replace ".log" ".rec")
    print $"TEST-START ($f)"
    let ns = (timeit {
        (run-external $raco "test" $f | complete | to json) | save --force $rp
    })
    let r = (open --raw $rp | from json)
    rm $rp
    let nl = (char newline)
    $"exit=($r.exit_code)($nl)($r.stdout)($r.stderr)" | save --force $lp
    let ms = (($ns | into int) / 1000000 | into int)
    print $"TEST-END ($f) exit=($r.exit_code) ms=($ms)"
    {file: $f, exit: $r.exit_code, ms: $ms}
}

# list -> list, one record per file, in the order given.
#
# `each` keeps the order and returns the list, so no mutable is needed and
# none may appear here: a closure cannot capture a mut in 0.116.1 (parse
# error). SLOWEST is the same top-10-by-duration summary check.sh prints
# from its temporary file, printed here instead of written to a temp file.
def run-all [files] {
    let recs = ($files | each {|f| run-child $f })
    print "SLOWEST:"
    let top = (if ($recs | is-empty) { [] } else { $recs | sort-by ms | reverse | first 10 })
    for r in $top {
        print $"  ($r.ms) ($r.file)"
    }
    $recs
}

# file -> record {file, exit, ms}, one `raco make -v`.
#
# Same shape as run-child and for the same reason: timeit returns only a
# duration and a closure may not capture a mutable, so the complete record
# is written inside the timed block and read back after it. Output goes to
# a "make" log so it does not overwrite the test log of the same file.
def compile-one [f] {
    let raco = (raco-exe)
    let lp = (log-path $f "make")
    let rp = ($lp | str replace ".log" ".rec")
    let ns = (timeit {
        (run-external $raco "make" "-v" $f | complete | to json) | save --force $rp
    })
    let r = (open --raw $rp | from json)
    rm $rp
    let nl = (char newline)
    $"exit=($r.exit_code)($nl)($r.stdout)($r.stderr)" | save --force $lp
    {file: $f, exit: $r.exit_code, ms: (($ns | into int) / 1000000 | into int)}
}

# list -> list of exit codes, sorted compile of every file.
#
# check.sh runs one `raco make -v` over the whole sorted list; this runs
# one per file so a failure names the file. Racket's compiled/ output
# stays in-tree (D-027): PLTCOMPILEDROOTS is deliberately not set here.
# The single STEP-END line is kept exactly as the old gate prints it.
def compile-all [files] {
    if ($files | is-empty) {
        print "STEP-END compile after=0ms"
        return []
    }
    let recs = ($files | sort | each {|f| compile-one $f })
    let total = ($recs | get ms | math sum)
    print $"STEP-END compile after=($total)ms"
    $recs | get exit
}
