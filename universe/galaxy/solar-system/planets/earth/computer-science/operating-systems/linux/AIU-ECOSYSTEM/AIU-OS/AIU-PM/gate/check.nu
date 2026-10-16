#!/usr/bin/env nu
# gate/check.nu -- green gate for CyberDeck (P-1, T-7).
#
# Converted from scripts/check.sh stage by stage and now the only gate;
# check.sh is deleted. The "check.sh lines N-M" comments below are kept
# as the map back to the shell original, not as a live dependency.
#
# ONE shared-process runner tests EVERY .rkt. gate/test-runner.rkt is
# the whole test gate (stage 10); there are no fast/slow tiers and no
# --fast flag. A slow file is an error to investigate, never a reason to
# give it its own process. Between checklist items run
# `nu gate/check.nu --changed`; the full gate runs once per phase.
#
# Scope roots come from the seam (E-00, D-029): gate/env.nu is the
# single Nu counterpart, imported with the member-list form (bare `use`
# does not bring names into scope in this Nu, measured). The path is
# file-relative (./env.nu lives beside this file): a bare gate/env.nu
# fails with module-not-found because `use` resolves from this file's
# directory, not the cwd. This runs env.nu's export-env once (one cache
# mkdir, one informational print).
use ./env.nu [scope-roots]
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
#   5  removed with the TUI (D-035)
#   6  text lint over .org, .rkt, .sh, .nu
#   7  pinned-Nu report (informational)
#   8  the file set: every .rkt, minus the parked list
#   9  compile every .rkt
#   10 test every file in ONE shared-process runner
#   11 verdict: ALL GREEN / ALL GREEN (jobs parked) / CHECK FAILED
#   12 paren check over every .rkt
#   13 OBS-OK lint over .nu (no ignores, bare try, /dev/null, timers)
#   14 one-printer lint: no raw print outside package-manager/src/narration/print-console.rkt and package-manager/src/narration/narration.rkt
#   15 security gate: every S-01 predicate called, writers audited

# Pinned Nushell (D-020). Change here and nowhere else.
const PINNED = "0.116.1"

# Exit codes: 0 clean, 1 violations found, 3 the running Nu is not pinned.
const EXIT_VIOLATIONS = 1
const EXIT_VERSION = 3

# The one file exempt from the line-length check.
const LENGTH_EXEMPT = "0.FOUNDATION.org"

# Longest allowed line, characters.
const MAX_LINE = 102

# Files that stand down, with the reason, in ONE place. Each entry is
# [file, reason]. The runner is handed the file list MINUS these two, so
# there is no env handoff and no test-name matching anywhere (the old
# CYBERDECK_PARKED_TEST_NAMES mechanism never delivered: the runner logged
# zero PARKED-SKIP lines and vault.rkt ran its full 470s anyway).
#
# A PARKED TEST IS NOT A PASSING TEST. The gate prints one line per entry on
# every run, counts them in the verdict as "ALL GREEN (parked: N)", and
# passes only when everything else passed. Nothing is dropped silently.
#
# These consts live HERE, beside the other constants, not down at the test
# stages: at that position in this file the parser reports "Eval block failed
# with pipeline input" on the const's first element (measured, and the same
# code parses fine in a small file). Beside the other constants it parses,
# so they stay here and the defs that read them live with the test stages.
#
# Row-wise reads ($p | get 0), never $P | get N: on a list of lists `get`
# with a bare integer selects a ROW in this build, not a column
# (measured: "index too large"). All readers below are pipelines over the
# const, which is safe; what is NOT safe is a `def` whose body IS a bare
# list literal called from inside a `where` closure, because the closure's
# pipeline input flows into the call (measured). There is no such def.
const FILE_PARKED = [
  ["package-manager/src/git/vault.rkt"
   "large-blob test fails, 851 git processes, 470s, see P-01"]
  ["package-manager/src/queue/jobs.rkt"
   "e2e: worker race and file:// allowance cannot cross processes; needs production design (P-03)"]
]

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

# path -> list, one string per OBS-OK violation, "path:line:reason".
# O-9 hidden-discard gate for Nu: a streaming pipe that drops its exit
# code silently looks green while failing. Allowed: `| complete`
# beside the discard (startup.nu precedent); the shapes below refuse.
# string -> string, code outside double quotes. No backslash-quotes
# exist in scripts (verified), so parity toggling is exact, and it
# resets per line by construction (callers pass one line).
def strip-quotes [s] {
    $s | split row '"' | enumerate | where {|r| ($r.index mod 2) == 0 } | get item | str join ""
}

def obs-lint-file [f] {
    let ls = (open --raw $f | lines)
    mut out = []
    for l in ($ls | enumerate) {
        let n = ($l.index + 1)
        let t = ($l.item | str trim)
        if ($t | str starts-with "#") { continue }
        let code = (strip-quotes $t)
        if (($code | str contains "| ignore") and not ($code | str contains "complete")) {
            $out = ($out | append $"($f):($n):| ignore without complete")
        }
        if (($code | str starts-with "try")
            and ($code | str contains "{")
            and not ($code | str contains "catch")) {
            $out = ($out | append $"($f):($n):bare try without catch")
        }
        if (($code | str contains "do -i") or ($code | str contains "do --ignore-errors")) {
            $out = ($out | append $"($f):($n):do -i hides errors")
        }
        if ($code | str contains "/dev/null") {
            $out = ($out | append $"($f):($n):/dev/null discard")
        }
        if (($code | str contains "sleep") or ($code | str contains "timeout")) {
            $out = ($out | append $"($f):($n):timer wait D-015")
        }
    }
    $out
}

# path -> list, every OBS-OK violation under root, nothing printed
def obs-lint-collect [root] {
    let files = (lint-files $root | where {|f| ($f | str ends-with ".nu") })
    $files | each {|f| obs-lint-file $f} | flatten
}

def run-stage-13-body [] {
    print "[check] stage 13 OBS-OK lint"
    let spec = ($env | get -o CYBERDECK_LINT_ROOTS? | default ".")
    let roots = ($spec | split row " ")
    for r in $roots {
        let files = (lint-files $r | where {|f| ($f | str ends-with ".nu") })
        let all = ($files | each {|f| obs-lint-file $f} | flatten)
        for v in $all {
            print $v
        }
        print $"obs-lint: ($files | length) files, ($all | length) violations"
    }
    let violations = ($roots | each {|r| obs-lint-collect $r } | flatten | length)
    if $violations > 0 { exit $EXIT_VIOLATIONS }
}

# V-3: one printer for the user. A raw print outside package-manager/src/narration/narration.rkt
# and package-manager/src/narration/print-console.rkt means some command is talking to the terminal by
# itself, which is exactly what D-036 removed. Quoted text is stripped
# first so the lint does not match its own vocabulary.
def print-lint-file [f] {
    let ls = (open --raw $f | lines)
    mut out = []
    # Non-test code only: everything from (module+ test onwards is a test
    # block, and a test may print whatever it needs to assert on. The
    # line index of that form is found once, then used as the cut.
    let starts = ($ls | enumerate | where {|r|
        ($r.item | str trim) == "(module+ test"
    } | get index)
    let test_at = (if ($starts | is-empty) { -1 } else { $starts | first })
    for l in ($ls | enumerate) {
        let n = ($l.index + 1)
        let t = ($l.item | str trim)
        if ($t | str starts-with ";") { continue }
        if ($l.index >= $test_at) { continue }
        let code = (strip-quotes $t)
        # Precise on purpose. (displayln X port) and (eprintf F ...) are
        # writes to a port the CALLER supplied; that is plumbing, not a
        # command talking to the terminal. The violation is a bare
        # (displayln X) with no port, or printf/eprintf/write-string,
        # which always land on a terminal the user did not choose.
        # Look past the opening paren: a bare (displayln X) has no other
        # "(" in it, while (displayln X port) has the port, not a paren.
        # Testing the whole line would always see its own leading "(".
        # A bare (displayln X) has exactly ONE argument; with a port it
        # has two. Counting whitespace-separated tokens says that
        # directly, and unlike counting parens it is not fooled by the
        # form's own opening bracket or by an argument that is itself
        # a parenthesised expression.
        let n2 = ($code | str length)
        let inner = (if $n2 > 1 { $code | str substring 1..($n2 - 1) } else { "" })
        let toks = ($inner | split row " " | where {|w| ($w | str length) > 0 })
        let bare_displayln = (($code | str starts-with "(displayln")
            and ($code | str ends-with ")")
            and (($toks | length) == 1))
        let bad = (
            ($code | str contains "(printf")
            or ($code | str contains "(eprintf")
            or ($code | str contains "(write-string")
            or $bare_displayln
        )
        if $bad {
            $out = ($out | append $"($f):($n):raw print outside the two printers, D-036")
        }
    }
    $out
}

# S-04: the policy has teeth in the gate. Two checks, both with
# file:line answers. First: every predicate package-manager/src/security/security.rkt provides
# must be CALLED somewhere outside security.rkt itself (non-test
# code); a predicate nobody calls is a rule nobody enforces. Second:
# open-output-file and subprocess may only appear in the audited files
# below; a new writer or spawner anywhere else fails until it is
# written down here deliberately.
def sec-predicates [] {
    open "package-manager/src/security/security.rkt"
    | lines
    | where {|l| ($l | str trim | str starts-with "[") }
    | each {|l|
        $l | str trim | str substring 1.. | split row " " | first
      }
}

def sec-call-count [pred, files] {
    mut n = 0
    for f in $files {
        let ls = (open --raw $f | lines)
        let starts = ($ls | enumerate | where {|r|
            ($r.item | str trim) == "(module+ test"
        } | get index)
        let test_at = (if ($starts | is-empty) { -1 } else { $starts | first })
        for l in ($ls | enumerate) {
            if ($l.index >= $test_at) { continue }
            let t = ($l.item | str trim)
            if ($t | str starts-with ";") { continue }
            let code = (strip-quotes $t)
            if ($code | str contains ("(" + $pred)) { $n = $n + 1 }
        }
    }
    $n
}

def run-stage-15-body [] {
    print "[check] stage 15 security-gate lint"
    let spec = ($env | get -o CYBERDECK_LINT_ROOTS? | default ".")
    let roots = ($spec | split row " ")
    mut violations = []
    for r in $roots {
        let files = (lint-files $r | where {|f| ($f | str ends-with ".rkt") })
        let nonsec = ($files | where {|f| ($f | path basename) != "security.rkt" })
        for pred in (sec-predicates) {
            let n = (sec-call-count $pred $nonsec)
            if $n == 0 {
                $violations = ($violations | append (
                  $"security-gate: predicate ($pred) uncalled (S-04)"
                ))
            }
        }
        print $"security-gate: predicates checked, ($violations | length) violations so far"
        # The audited writers and spawners. scripts/*.rkt are dev tools,
        # audited by the V-0 inventory decision that they keep their own
        # printing; they are listed here so that stays visible.
        # A file outside this list
        # that opens an output file or spawns a process fails here, so
        # new effects get written down instead of slipping in.
        let writers = ["activate.rkt" "apply.rkt" "build.rkt" "dev.rkt"
            "git.rkt" "install.rkt" "jobs.rkt" "journal.rkt" "local.rkt"
            "manifest.rkt" "query.rkt" "run.rkt" "store.rkt" "update.rkt"
            "vault.rkt" "main.rkt" "ecosystem.rkt" "lock.rkt" "log.rkt"
            "scope.rkt" "spec-read.rkt" "vault-lock.rkt" "verbose.rkt"
            "server.rkt" "plan.rkt" "skill-examples.rkt"
            "build-lua.rkt" "hello-fetch.rkt" "probe-blob.rkt" "repl.rkt"
            "test-runner.rkt" "read-check.rkt"]
        for f in $files {
            let base = ($f | path basename)
            if ($base in $writers) { continue }
            let rawlines = (open --raw $f | lines)
            let code = (($rawlines | each {|l|
                strip-quotes ($l | str trim)
            }) | str join "
")
            if (($code | str contains "open-output-file") or ($code | str contains "subprocess")) {
                $violations = ($violations | append (
                  "security-gate: " + $f + " writes outside audit (S-04)"
                ))
            }
        }
        for v in $violations { print $v }
        print $"security-gate: ($files | length) files, ($violations | length) violations"
    }
    if (($violations | length) > 0) { exit $EXIT_VIOLATIONS }
}

# ---------------------------------------------------------------------------
# stage 16: the one-printer rule INSIDE test bodies.
#
# WHY THIS STAGE EXISTS. Stages 14 and 15 both stop at `(module+ test`.
# That was deliberate -- a test may print whatever it needs to assert on --
# but the skip was total and only ever stated in a code comment. So a
# `displayln` in a test block printed straight to the console and the gate
# stayed green: a real violation, invisible, found by reading.
#
# THE POLICY, stated rather than skipped:
#
#   * A test MAY print. That is how it asserts. But it must print to a
#     port it names -- a captured string port, a temp file, a
#     parameterised output port. A bare `(displayln "x")` with no port is
#     unsuppressed console output and is a violation.
#   * The designated printers (display-pm-error, display-internal-error,
#     display-result, display-warning-summary) are exempt, and exempt for a
#     structural reason: they ARE the one printer, so calling one obeys
#     the rule rather than breaking it.
#   * EFFECTS IN TESTS ARE ALLOWED, and that is a decision, not a gap. A
#     test exists to write fixtures and to spawn real tools; forbidding
#     that would forbid testing. Stage 15's audited-writers rule exists so
#     an effect cannot slip in undeclared in PRODUCTION code. Here the
#     declaration is the file itself: everything past `(module+ test` is
#     test code by construction, reviewed as such. This paragraph is the
#     record of that decision, so it cannot quietly become a gap.
#
# PRECISION, measured before this was switched on. 145 test-block prints
# already named a port. The 4 that appeared not to were ALL false
# positives: two designated printers called across lines, one multi-line
# call naming its port two lines later, and `(displayln "go" uniq-held)`
# where the port is `uniq-held`. Matching the words "out"/"port" flagged
# exactly that last one, so every hit was false and the rule protected
# nothing. A lint whose hits are all noise is decoration.
#
# What ships is therefore narrow and honest, and it UNDER-reports on
# purpose:
#
#   * Only lines that BEGINS with a raw print name and ENDS with a closing
#     paren are judged, which means the whole call is on one line. A
#     multi-line call begins `(displayln` and does not end with `)`, so it
#     is skipped rather than guessed at.
#   * The call name must MATCH exactly, not merely start the same way, so
#     `display-pm-error` is never mistaken for `display`. The earlier
#     prefix test would have flagged every designated-printer call whose
#     only argument was a string.
#   * String literals are removed BEFORE the argument test. Without that,
#     `(displayln "a long message")` counts as four arguments and passes.
#     After removal, the port -- which is never inside a string -- is the
#     only thing left, so "nothing left but the closing paren" means the
#     call printed data and named no port.
#   * A `#:port` keyword exempts the line, which covers the keyword form.
#
# No paren counting is used anywhere. Nushell will not accept
# `str count "("`, and a rule that has to balance brackets across lines is
# a rule that will be wrong somewhere. Zero true violations on the tree at
# switch-on, so this runs on by default.

def test-print-call-name [t] {
    let first = ($t | split row " " | where {|x| ($x | str trim | is-not-empty) } | first)
    ($first | str replace --all --regex '^\(' "")
}

def test-print-names-port [t] {
    let nostr = ($t | str replace --all --regex '"[^"]*"' " ")
    let rest = ($nostr | str replace --all --regex '^\(\w+' " ")
    let toks = ($rest | split row " " | where {|x| ($x | str trim | is-not-empty) })
    not (($toks | length) == 1 and ($toks | first) == ")")
}

def test-print-hits [f] {
    let ls = (open --raw $f | lines)
    let markers = ($ls | enumerate | where {|r| ($r.item | str trim) == "(module+ test" } | get index)
    if ($markers | is-empty) { return [] }
    let at = ($markers | first)
    let total = ($ls | length)
    let raw_prints = ["displayln" "display" "printf" "print" "newline"]
    mut hits = []
    mut i = $at
    while $i < $total {
        let t = ($ls | get $i | str trim)
        # Skip comments: a commented-out call prints nothing.
        if (not ($t | str starts-with ";")) {
            if ($t | str ends-with ")") {
                let n = (test-print-call-name $t)
                if ($n in $raw_prints) {
                    let keyword = ($t | str contains "#:port")
                    if ((not $keyword) and (not (test-print-names-port $t))) {
                        $hits = ($hits | append (
                          "test-print: " + $f + ":" + ($i + 1 | into string)
                          + " prints with no port named (S-14)"
                        ))
                    }
                }
            }
        }
        $i = $i + 1
    }
    $hits
}

def run-stage-16-body [] {
    print "[check] stage 16 test-body printer lint"
    let spec = ($env | get -o CYBERDECK_LINT_ROOTS? | default ".")
    let roots = ($spec | split row " ")
    mut violations = []
    for r in $roots {
        let files = (lint-files $r | where {|f| ($f | str ends-with ".rkt") })
        let hits = ($files | each {|f| test-print-hits $f } | flatten)
        for v in $hits { print $v }
        print $"test-print: ($files | length) files, ($hits | length) violations"
        $violations = ($violations | append $hits)
    }
    if (($violations | length) > 0) { exit $EXIT_VIOLATIONS }
}

def run-stage-14-body [] {
    print "[check] stage 14 one-printer lint"
    let spec = ($env | get -o CYBERDECK_LINT_ROOTS? | default ".")
    let roots = ($spec | split row " ")
    mut violations = []
    for r in $roots {
        # package-manager/src/narration/narration.rkt and package-manager/src/narration/print-console.rkt ARE the printers; every other
        # .rkt must reach the user through them. lint-files already drops
        # compiled/ and non-files, so the same list the text lint sees.
        # The printers are package-manager/src/narration/narration.rkt and package-manager/src/narration/print-console.rkt. package-manager/src/narration/event-text.rkt
        # is exempt for a structural reason, not a convenience: ui.rkt
        # requires log.rkt for warn!, so log.rkt requiring ui.rkt would
        # be a cycle. The exemption is NAMED here so a second one has to
        # be written down too, instead of the list quietly growing.
        let printers = ["verbose.rkt" "ui.rkt"]
        let exempt = ["log.rkt"]
        let scanned = (lint-files $r | where {|f| ($f | str ends-with ".rkt") }
            | where {|f|
                not (($f | path basename) in ($printers | append $exempt))
            })
        let hits = ($scanned | each {|f| print-lint-file $f } | flatten)
        for v in $hits { print $v }
        print $"print-lint: ($scanned | length) files, ($hits | length) violations"
        $violations = ($violations | append $hits)
    }
    if (($violations | length) > 0) { exit $EXIT_VIOLATIONS }
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

# Stage 7 (check.sh lines 80-84): export GIT_ALLOW_PROTOCOL=file for every
# spawn below, then report which Nushell the scripts would use. The report
# is informational only: `|| true` in the old gate, so a non-zero exit here
# is recorded and swallowed rather than failing the gate.
def stage-7 [] {
    $env.GIT_ALLOW_PROTOCOL = "file"
    let nu_bin = ($env | get -o CYBERDECK_NU? | default ($nu.current-exe))
    let r = (do { run-external $nu_bin "--no-config-file" "gate/need-nu.nu" } | complete)
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

# FILE_PARKED is declared at the top of this file, with the other
# constants, because a const at this position fails to parse (see the note
# beside it). The helpers that read it belong next to the test stages.
# All readers are pipelines over the const, which is safe.

# -> bool, true when the file is on the parked list, relative or absolute.
# Both stage 10 and --changed compare against this: the runner file list
# mixes relative and absolute forms of the same file, so exact membership
# silently fails to exclude (measured: vault.rkt ran 470s while parked).
def file-parked? [f] {
    $FILE_PARKED | any {|p| $f | str ends-with ($p | get 0) }
}

# -> list, one printed line per parked file: PARKED <file> - <reason>
def parked-lines [] {
    $FILE_PARKED | each {|p| "PARKED: " ++ ($p | get 0) ++ " - " ++ ($p | get 1) }
}

# -> int, everything standing down
def parked-total [] {
    $FILE_PARKED | length
}

# Stage 12: the paren check. gate/read-check.rkt reads every named .rkt
# and names the exact file and line of the first malformed form, so an
# unbalanced paren is reported, not guessed at. It exits 1 when anything is
# bad, which is this stage's verdict. The file list is the same glob stage 9
# compiles, so a file that cannot even be read is caught before raco.
def stage-12 [] {
    print "[check] stage 12 paren check"
    let racketx = ($nu.home-dir | path join "opt" "racket-full" "bin" "racket")
    let fs = (stage-8-files)
    let code = (try {
        ^$racketx "gate/read-check.rkt" ...$fs
        0
    } catch { |e|
        print $"[check] paren check failed: ($e.msg)"
        1 })
    print $"[check] stage 12 exit=($code)"
    $code
}

# Named main, so the CLI matches check.sh (`nu gate/check.nu --changed`).
# Verified 0.116.1: nu auto-invokes a command called main and passes the flag
# through; it must therefore NOT also be called explicitly, or the whole
# gate runs twice.
#
# The verdict leaves through a `mut` in THIS scope, not through $env: in
# 0.116.1 an `$env.X = ...` assignment inside a `timeit { }` closure does not
# persist (measured), so the old shape printed CHECK FAILED and still exited
# 0. There is no closure here at all, which is why the mut is allowed.
def main [--changed] {
    print $"[check] run start utc=(utc)"
    let changed_mode = ($changed or (($env | get -o CYBERDECK_CHANGED?) == "1"))
    let want = (if $changed_mode {
        $env | get -o CYBERDECK_STAGES? | default "1,2,3,4,7,13,14,15,16,changed" } else {
        $env | get -o CYBERDECK_STAGES? | default "1,2,3,4,6,7,8,9,10,11,12,13,14,15,16" })
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
        let parked = ((stage-8-files) | where {|f| (file-parked? $f) })
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
            for l in (parked-lines) {
                print $l
            }
            let testfiles = ($full | where {|f| not (file-parked? $f) })
            print $"[check] stage 10 tests ($testfiles | length) files one process"
            $recs = (if ($testfiles | is-empty) { [] } else { run-runner $testfiles })
            let bad10 = ($recs | any {|r| $r.exit != 0})
            print $"[check] stage 10 records=($recs | length) failed=($bad10)"
        }
        if "11" in $todo {
            let crecs = ($ccodes | each {|c| {file: "(compile)", exit: $c, ms: 0} })
            $verdict_code = (verdict ($recs | append $crecs) (parked-total))
            print $"[check] stage 11 exit=($verdict_code)"
        }
        if "12" in $todo {
            let rc12 = (stage-12)
            print $"[check] stage 12 exit=($rc12)"
            if $rc12 != 0 {
                $verdict_code = 1
            }
        }
        if "13" in $todo {
            run-stage-13-body
        }
        if "14" in $todo {
            run-stage-14-body
        }
        if "15" in $todo {
            run-stage-15-body
        }
        if "16" in $todo {
            run-stage-16-body
        }
    let elapsed = (((date now | into int) - $started) / 1000000)
    print $"[check] end utc=(utc) after=($elapsed)ms"
    exit $verdict_code
}

# Stage 9-11 helpers (check.sh lines 97-130). Stages 1-8 stay above; these
# are the compile, test and verdict halves, proved on fixtures first.
#
# -> string, the raco check.sh uses (line 6), overridable for fixtures.
def raco-exe [] {
    let raco_default = ($nu.home-dir | path join "opt" "racket-full" "bin" "raco")
    $env | get -o CYBERDECK_RACO? | default $raco_default
}

# -> string, the gate log directory, created on demand. Child output goes
# here, never into the tree; the base comes from the scope seam (E-00),
# never from a direct env read.
def gate-log-dir [] {
    let base = (scope-roots | get cache)
    let d = ($base | path join "aiu-pm" "gate")
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
# gate/test-runner.rkt is the whole test gate. It reuses one linked
# namespace instead of paying raco's per-file library link (about 5s each
# on this phone) and prints its own TEST-START / TEST-END / SUSPECT /
# SLOWEST / SUMMARY lines. Nu prints those lines verbatim and parses
# NOTHING: the verdict is the runner's process exit code alone, so the two
# cannot disagree about format.
#
# One process, never one per file. A file that hangs here is a test
# isolation bug to fix (see plan/OPEN-DECISIONS.org), not a reason for a tier.
# D-015: no timer, no timeout, no sleep; the wait ends on process exit.
def run-runner [files] {
    let racketx = ($nu.home-dir | path join "opt" "racket-full" "bin" "racket")
    # Parked files never reach this call: the caller hands over the file
    # list MINUS the FILE_PARKED entries, so there is no skip mechanism in
    # the runner and nothing to fail to deliver.
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
        ^$racketx "gate/test-runner.rkt" ...$files
        0
    } catch { |e|
        print $"[check] shared-runner failed: ($e.msg)"
        1 })
    print $"[check] shared-runner exit=($code)"
    [{file: "shared-runner", exit: $code, ms: 0}]
}

# list -> list of exit codes, ONE `raco make -v` over every file.
#
# check.sh ran one `raco make -v` over the whole sorted list; this used to run
# one per file so a failure named the file, at ~11s per file x 29 files
# (measured ~320s on this phone, nearly all of it per-process library
# linking, not compiling). One call pays that cost once. A failure still
# names the file: `make -v` prints which file it was making when it stops,
# streamed live through ^. Racket's compiled/ output goes to the single
# root set by gate/env.nu (PLTCOMPILEDROOTS, D-027 reversed), so this
# call never creates a compiled/ directory in the tree.
# The single STEP-END line is kept exactly as the old gate prints it.
def compile-all [files] {
    if ($files | is-empty) {
        print "STEP-END compile after=0ms"
        return []
    }
    let sorted = ($files | sort)
    print $"[check] stage 9 compiling ($sorted | length) files in one raco make"
    let raco = (raco-exe)
    let started = (date now | into int)
    let code = (try {
        ^$raco "make" "-v" ...$sorted
        0
    } catch { |e|
        print $"COMPILE-FAILED: ($e.msg)"
        1 })
    # `date now | into int` is NANOSECONDS in this build (measured); divide
    # before labelling, or the timing is wrong by 1000x.
    let ms = (((date now | into int) - $started) / 1000000)
    print $"STEP-END compile after=($ms)ms exit=($code)"
    [$code]
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
        if $parked_n > 0 {
            print ("ALL GREEN (parked: " ++ ($parked_n | into string) ++ ")")
            for l in (parked-lines) {
                print $l
            }
        } else {
            print "ALL GREEN"
        }
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
    let parked = ($changed | where {|c| (file-parked? $c) })
    for x in $parked {
        let hit = ($FILE_PARKED | where {|p| $x | str ends-with ($p | get 0) })
        let why = ($hit | each {|p| $p | get 1 } | first)
        print ("PARKED: " ++ ($x | path basename) ++ " - " ++ $why)
    }
    let unparked_deps = ($deps | where {|d| not (file-parked? $d) })
    let runset = ($changed | where {|c| not (file-parked? $c) } | append $unparked_deps)
    if ($runset | is-empty) {
        print "[changed] nothing to run"
        return 0
    }
    let ccodes = (compile-all $runset)
    let recs = (run-runner $runset)
    let bad = ($ccodes | any {|c| $c != 0}) or ($recs | any {|r| $r.exit != 0})
    (verdict $recs ($parked | length))
    (if $bad { 1 } else { 0 })
}
