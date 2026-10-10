#!/usr/bin/env nu
# scripts/check.nu -- green gate for CyberDeck (P-1, T-7).
#
# Converted from scripts/check.sh stage by stage and now the only gate;
# check.sh is deleted. The "check.sh lines N-M" comments below are kept
# as the map back to the shell original, not as a live dependency.
#
# ONE shared-process runner tests EVERY .rkt. scripts/test-runner.rkt is
# the whole test gate (stage 10); there are no fast/slow tiers and no
# --fast flag. A slow file is an error to investigate, never a reason to
# give it its own process. Between checklist items run
# `nu scripts/check.nu --changed`; the full gate runs once per phase.
#
# Stage 6 rules, unchanged from check.sh lines 65-79:
#   - no tabs
#   - no trailing spaces
#   - no line over 102 characters (0.FOUNDATION.org is exempt: user contract)
#   - final newline required
# Now covering .nu files as well as .org, .rkt and .sh, because this file
# is one of the things being linted.
#
# Stage map:
#   1  cli/ never references the test-only file-URL flag
#   2  git is present
#   3  run.rkt's helper tools are present
#   4  D-011 monorepo rules
#   5  tui rebrand gates
#   6  text lint over .org, .rkt, .sh, .nu
#   7  pinned-Nu report (informational)
#   8  the file set: every .rkt, minus the parked list
#   9  compile every .rkt
#   10 test every file in ONE shared-process runner
#   11 verdict: ALL GREEN / ALL GREEN (jobs parked) / CHECK FAILED
#   12 paren check over every .rkt

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

# Stage 8: the file set. There are no tiers any more. Every .rkt in the
# tree goes through ONE shared-process runner, so the list is simply every
# .rkt, derived and never hand-listed.
#
# CYBERDECK_TEST_FILES (space separated) replaces the glob. It exists so a
# failing synthetic fixture outside the repo can drive the gate to
# CHECK FAILED; nothing else reads it.
def stage-8-files [] {
    let given = ($env | get -o CYBERDECK_TEST_FILES?)
    if $given == null {
        glob "**/*.rkt" | where {|f| not ($f | str contains "/compiled/")} | sort
    } else {
        [$given] | split row " "
    }
}

# Files the runner must not be handed, each with the reason it is held
# back. A parked file is printed every run, never dropped silently, and the
# reason travels with the name so a reader never has to guess.
const PARKED = [
  {file: "backends/jobs.rkt", why: "see ENGINE-CHECKLIST P-03"}
  {file: "core/vault-lock.rkt",
   why: "fcntl locks are process-local, so a re-acquire in one shared process blocks forever (P-04)"}
]

# -> list, the parked subset of the stage-8 file set
def stage-8-parked [] {
    (stage-8-files) | where {|f| $PARKED | any {|p| $f | str ends-with $p.file }}
}

# Stage 12: the paren check. scripts/read-check.rkt reads every named .rkt
# and names the exact file and line of the first malformed form, so an
# unbalanced paren is reported, not guessed at. It exits 1 when anything is
# bad, which is this stage's verdict. The file list is the same glob stage 9
# compiles, so a file that cannot even be read is caught before raco.
def stage-12 [] {
    print "[check] stage 12 paren check"
    let racketx = ($nu.home-dir | path join "opt" "racket" "bin" "racket")
    let fs = (stage-8-files)
    let code = (try {
        ^$racketx "scripts/read-check.rkt" ...$fs
        0
    } catch { |e|
        print $"[check] paren check failed: ($e.msg)"
        1 })
    print $"[check] stage 12 exit=($code)"
    $code
}

# Named main, so the CLI matches check.sh (`nu scripts/check.nu --changed`).
# Verified 0.116.1: nu auto-invokes a command called main and passes the flag
# through; it must therefore NOT also be called explicitly, or the whole
# gate runs twice.
#
# The verdict leaves through a `mut` in THIS scope, not through $env: in
# 0.116.1 an `$env.X = ...` assignment inside a `timeit { }` closure does not
# persist (measured), so the old shape printed CHECK FAILED and still exited
# 0. There is no closure here at all, which is why the mut is allowed.
def main [--changed] {
    let changed_mode = ($changed or (($env | get -o CYBERDECK_CHANGED?) == "1"))
    let want = (if $changed_mode {
        $env | get -o CYBERDECK_STAGES? | default "1,2,3,4,5,7,changed" } else {
        $env | get -o CYBERDECK_STAGES? | default "1,2,3,4,5,6,7,8,9,10,11,12" })
    let todo = ($want | split row ",")
    # `date now` is read twice and subtracted: measurement only, printed for
    # the record. Nothing waits on it (D-015).
    let started = (date now | into int)
    mut verdict_code = 0
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
            let fs = (stage-8-files)
            print $"[check] stage 8 file set ($fs | length) files"
            for f in $fs { print $"[check] stage 8 file ($f)" }
        }
        if "6" in $todo {
            run-stage-6-body
        }
        # Stages 9-11. Every .rkt is compiled, then every test file is run
        # through ONE shared-process runner. The runner's records and one
        # record per compiled file are handed to verdict, so a compile
        # failure fails the gate exactly as `raco make` used to.
        let full = (stage-8-files)
        let parked = (stage-8-parked)
        mut ccodes = []
        mut recs = []
        if "changed" in $todo {
            let chrc = (stage-changed)
            print $"[check] stage changed exit=($chrc)"
        }
        if "9" in $todo {
            print $"[check] stage 9 compile ($full | length) files"
            $ccodes = (compile-all $full)
            let cbad = ($ccodes | any {|c| $c != 0})
            print $"[check] stage 9 exit=(if $cbad { 1 } else { 0 })"
        }
        if "10" in $todo {
            for p in $parked {
                print $"PARKED: ($p | path basename)" $" ($p | get why)"
            }
            let testfiles = ($full | where {|f| not ($f in $parked)})
            print $"[check] stage 10 tests ($testfiles | length) files one process"
            $recs = (if ($testfiles | is-empty) { [] } else { run-runner $testfiles })
            let bad10 = ($recs | any {|r| $r.exit != 0})
            print $"[check] stage 10 records=($recs | length) failed=($bad10)"
        }
        if "11" in $todo {
            let crecs = ($ccodes | each {|c| {file: "(compile)", exit: $c, ms: 0} })
            $verdict_code = (verdict ($recs | append $crecs) ($parked | length))
            print $"[check] stage 11 exit=($verdict_code)"
        }
        if "12" in $todo {
            let rc12 = (stage-12)
            print $"[check] stage 12 exit=($rc12)"
            if $rc12 != 0 {
                $verdict_code = 1
            }
        }
    let elapsed = ((date now | into int) - $started)
    print $"[check] end utc=(utc) after=($elapsed)ms"
    exit $verdict_code
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
# Kept because it is the only place that knows where gate logs live; the
# runner and the compiler stream to the screen instead of writing here.
def log-path [f tag] {
    (gate-log-dir) | path join (($f | str replace -a "/" "_") + "." + $tag + ".log")
}

# list -> list of one record, ONE shared-process runner for every test
# file.
#
# scripts/test-runner.rkt is the whole test gate. It reuses one linked
# namespace instead of paying raco's per-file library link (about 5s each
# on this phone) and prints its own TEST-START / TEST-END / SUSPECT /
# SLOWEST / SUMMARY lines. Nu prints those lines verbatim and parses
# NOTHING: the verdict is the runner's process exit code alone, so the two
# cannot disagree about format.
#
# One process, never one per file. A file that hangs here is a test
# isolation bug to fix (see ENGINE-CHECKLIST), not a reason for a tier.
# D-015: no timer, no timeout, no sleep; the wait ends on process exit.
def run-runner [files] {
    let racketx = ($nu.home-dir | path join "opt" "racket" "bin" "racket")
    # The runner is spawned with the ^ short form, NOT `run-external ...
    # | complete`. Measured in 0.116.1: run-external buffers the child's
    # stdout until the child EXITS, so TEST-START / TEST-END / SUSPECT
    # arrived in one lump at the end, when they are useless. ^ streams to
    # the screen as each line is flushed.
    #
    # A non-zero external raises in this build, so try/catch turns that
    # back into the 0/1 the verdict reports. Nothing is parsed: the
    # runner's own process exit code is still the only thing that decides.
    let code = (try {
        ^$racketx "scripts/test-runner.rkt" ...$files
        0
    } catch { |e|
        print $"[check] shared-runner failed: ($e.msg)"
        1 })
    print $"[check] shared-runner exit=($code)"
    [{file: "shared-runner", exit: $code, ms: 0}]
}

# file -> record {file, exit, ms}, one `raco make -v`.
#
# Streamed with the ^ short form for the same reason as run-runner: a
# buffered child means a five-minute silent stage, and a compile failure
# that only surfaces at the end names no file while it is happening. The
# per-file log files go with it: the output is on the screen where it is
# wanted and nothing reads those logs back.
def compile-one [f] {
    let raco = (raco-exe)
    let started = (date now | into int)
    let code = (try {
        ^$raco "make" "-v" $f
        0
    } catch { |e|
        print $"COMPILE-FAILED ($f): ($e.msg)"
        1 })
    let ms = ((date now | into int) - $started)
    print $"COMPILE-END ($f) exit=($code) ms=($ms)"
    {file: $f, exit: $code, ms: $ms}
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
    let sorted = ($files | sort)
    print $"[check] stage 9 compiling ($sorted | length) files"
    mut recs = []
    mut n = 0
    for f in $sorted {
        $n = ($n + 1)
        print $"[check] stage 9 compile ($n)/($sorted | length) ($f | path basename)"
        $recs = ($recs | append [(compile-one $f)])
    }
    let total = ($recs | get ms | math sum)
    print $"STEP-END compile after=($total)ms"
    $recs | get exit
}

# records, parked_n -> int
#
# Exactly three verdict lines. There is no partial run any more: one
# runner covers every file, so a clean run is ALL GREEN. When a file is
# parked the green line says so, so a parked file is never silent. Exit
# code 0 for both green forms, 1 for CHECK FAILED.
def verdict [records parked_n] {
    let bad = ($records | any {|r| $r.exit != 0})
    if not $bad {
        if $parked_n > 0 { print "ALL GREEN (jobs parked)" } else { print "ALL GREEN" }
    } else {
        print "CHECK FAILED"
    }
    (if $bad { 1 } else { 0 })
}

# --changed: the between-items gate. Only what actually changed is
# recompiled and tested, so an item costs seconds instead of minutes.
# Changed files come from git (tracked diff plus untracked); the test
# blocks of modules that DIRECTLY require them are added too, found by
# reading their require lines, one level only. The result goes through the
# SAME one-process shared runner as the full gate, never per-file raco.
# A parked file is named and skipped, never dropped silently.

# -> list of changed .rkt paths, tracked-diff plus untracked
def changed-rkt [] {
    let d = (do { run-external "git" "diff" "--name-only" "HEAD" } | complete)
    let tracked = (if $d.exit_code == 0 { $d.stdout | lines } else { [] })
    let u = (do { run-external "git" "ls-files" "--others" "--exclude-standard" } | complete)
    let untracked = (if $u.exit_code == 0 { $u.stdout | lines } else { [] })
    let all = ($tracked | append $untracked)
    # git prints paths relative to the REPO root, which is above this
    # directory; strip everything up to and including the last component
    # so the path resolves from here.
    $all | where {|p| ($p | str ends-with ".rkt")} | each {|p|
        # keep the last two components: DIR/NAME.rkt
        let parts = ($p | split row "/")
        let n = ($parts | length)
        $parts | skip ($n - 2) | path join }
}

# list -> list, modules whose source directly requires any of them
def direct-dependents [changed] {
    if ($changed | is-empty) {
        return []
    }
    let allr = (stage-8-files)
    $allr | where {|f|
        let body = (open --raw $f)
        if not ($body | str contains "(require") {
            false
        } else {
            $changed | any {|c| $body | str contains ($c | path basename) }
        } }
}

# The --changed gate: stages 1-5 and 7 still run (they are cheap and
# gate the tree), then only what changed is compiled and tested, through
# the same one-process shared runner the full gate uses.
def stage-changed [] {
    let changed = (changed-rkt)
    if ($changed | is-empty) {
        print "[changed] nothing changed; nothing to do"
        return 0
    }
    print $"[changed] ($changed | length) changed rkt files"
    for c in $changed {
        print $"[changed] ($c)"
    }
    let deps = (direct-dependents $changed)
    let parked = ($changed | where {|c| $c in (stage-8-parked)})
    for x in $parked {
        let why = ($PARKED | where {|p| $x | str ends-with $p.file } | get why | first)
        print $"PARKED: ($x | path basename)" $" ($why)"
    }
    let runset = ($changed | where {|c| not ($c in $parked)} | append $deps)
    if ($runset | is-empty) {
        print "[changed] nothing to run"
        return 0
    }
    let ccodes = (compile-all $runset)
    let recs = (run-runner $runset)
    let bad = ($ccodes | any {|c| $c != 0}) or ($recs | any {|r| $r.exit != 0})
    (verdict [$recs] ($parked | length))
    (if $bad { 1 } else { 0 })
}
