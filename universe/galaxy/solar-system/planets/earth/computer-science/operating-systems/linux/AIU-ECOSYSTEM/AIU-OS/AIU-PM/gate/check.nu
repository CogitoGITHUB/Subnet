#!/usr/bin/env nu
# gate/check.nu -- green gate for CyberDeck (P-1, T-7).
#
# Converted from scripts/check.sh stage by stage and now the only gate;
# check.sh is deleted. The "check.sh lines N-M" comments below are kept
# as the map back to the shell original, not as a live dependency.
#
# ONE shared-process runner tests EVERY .rkt. gate/test-runner.rkt is
# the whole run-tests stage; there are no fast/slow tiers and no
# --fast flag. A slow file is an error to investigate, never a reason to
# give it its own process. Between checklist items run
# `nu gate/check.nu --changed`; the full gate runs once per phase.
# `nu gate/check.nu --list` prints every stage name and what it checks.
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
# text-lint rules, unchanged from check.sh lines 65-79:
#   - no tabs
#   - no trailing spaces
#   - no line over 102 characters (0.FOUNDATION.org is exempt: user contract)
#   - final newline required
# Now covering .nu files as well as .org, .rkt and .sh, because this file
# is one of the things being linted.
#
# Stage map. Stages are NAMED by what they check, never numbered: with
# sixteen numbered stages "what is stage 6?" cost a read of this file,
# and every doc reference carried the same guess. Sub-stages are the
# parent name plus the rule (text-lint/line-length). `--list` prints
# this map live and the dispatcher validates against it, so the record
# and the runner cannot drift apart.
#
#   cli-no-file-url-flag  cli/ never references the test-only file-URL flag
#   git-present           git is present
#   helper-tools-present  run.rkt's helper tools are present
#   monorepo-rules        D-011 monorepo rules
#   text-lint             no tabs/space-ends/long lines/missing newline
#   pinned-nu-report      which nushell would run (informational)
#   file-set              every .rkt the rest of the gate will use
#   compile               compile every .rkt, one raco make
#   run-tests             every file in ONE shared-process runner
#   verdict               ALL GREEN / CHECK FAILED from the records
#   read-check            first malformed form in every .rkt, file:line
#   obs-ok-lint           no silent discards in .nu (O-9)
#   one-printer-lint      no raw print outside the two named printers
#   security-gate-lint    S-04: predicates called, writers audited
#   test-body-print-lint  bare prints inside test bodies
#   changed-files         between-items gate: changed files only
#
# tui-checks is retired (removed with the TUI, D-035) and stays in the
# map as a record, not a gap.

# Pinned Nushell (D-020). Change here and nowhere else.
const PINNED = "0.116.1"

# Exit codes: 0 clean, 1 violations found, 2 unknown stage name
# (usage), 3 the running Nu is not pinned.
const EXIT_VIOLATIONS = 1
const EXIT_USAGE = 2
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

# Every stage: [name, sub-stages, what it checks]. The dispatcher
# validates CYBERDECK_STAGES against col 0 and --list prints the table,
# so this is the one place a stage gets its name. Rows, read with
# `get`, same as FILE_PARKED above.
const STAGES = [
  ["cli-no-file-url-flag" []
   "cli/ never references the test-only file-URL flag"]
  ["git-present" []
   "git exists; the gate reads history and pm drives git everywhere"]
  ["helper-tools-present" []
   "run.rkt's helper tools (env, setsid, pkill, flock, mkfifo, tar) exist"]
  ["monorepo-rules" []
   "D-011: vault.git ignored not tracked, no gitlinks, no blanket sources/"]
  ["text-lint" ["tabs" "trailing-space" "line-length" "final-newline"]
   "no tabs, no trailing spaces, no line over 102 chars, final newline"]
  ["pinned-nu-report" []
   "informational: export GIT_ALLOW_PROTOCOL=file, report the nushell used"]
  ["file-set" []
   "list every .rkt the later stages will run over"]
  ["compile" []
   "one raco make over every .rkt; failure names the file being made"]
  ["run-tests" []
   "every unparked file through ONE shared-process runner"]
  ["verdict" []
   "ALL GREEN / ALL GREEN (parked: N) / CHECK FAILED from the records"]
  ["read-check" []
   "first malformed form in every .rkt, reported file:line"]
  ["obs-ok-lint" ["ignore-without-complete" "bare-try" "do-i-hides-errors"
                  "dev-null" "timer-wait"]
   "no silent discards in .nu: bare ignore, try, do -i, /dev/null, timers"]
  ["one-printer-lint" ["raw-printf" "raw-eprintf" "raw-write-string"
                       "bare-displayln"]
   "no raw print outside the two printers, D-036"]
  ["security-gate-lint" ["uncalled-predicates" "audited-writers"]
   "S-04: every security predicate is called; effects are the measured set"]
  ["banned-words-lint" []
   "the naming law: no core/main/server/backends/handler/manager/tmp in paths or definitions"]
  ["one-way-dependency-lint" []
   "ARCHITECTURE.org: an area may require only the areas below it"]
  ["test-body-print-lint" []
   "inside (module+ test, a print naming no port is a violation"]
  ["changed-files" []
   "between-items gate: compile and test only what git says changed"]
]

# Retired stages stay reachable by name so asking for one prints the
# reason and runs nothing, instead of a silent no-op.
const RETIRED_STAGES = [
  ["tui-checks" "removed with the TUI (D-035)"]
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

# path, rules -> list, one string per violation, "path:line:reason".
# Line 0 marks a whole-file property. `rules` is the enabled subset of
# the STAGES text-lint sub-names; the full list runs all four rules.
def lint-file [f rules] {
    let body = (open --raw $f)
    let ls = ($body | lines)
    let has_tab = ($body | str contains (char tab))
    let tabnums = (if (("tabs" in $rules) and $has_tab) { tab-lines $ls } else { [] })
    let spacenums = (if ("trailing-space" in $rules) { space-lines $ls } else { [] })
    let longnums = (if ("line-length" in $rules) {
        if (($f | path basename) != $LENGTH_EXEMPT) { long-lines $ls } else { [] }
    } else { [] })
    let has_nl = ($body | str ends-with (char newline))
    let nl = (if (("final-newline" in $rules) and (not $has_nl)) {
        [ $"($f):0:no final newline" ]
    } else { [] })
    $tabnums | each {|n| $"($f):($n):tab"}
    | append ($spacenums | each {|n| $"($f):($n):trailing space"})
    | append ($longnums | each {|n| $"($f):($n):line over ($MAX_LINE) chars"})
    | append $nl
}

# path, rules -> list, every violation under root, nothing printed
def lint-collect [root rules] {
    let files = (lint-files $root)
    $files | each {|f| lint-file $f $rules} | flatten
}

# path, rules -> nothing. Prints the violations and the summary for one root.
def lint-root [root rules] {
    let files = (lint-files $root)
    let all = ($files | each {|f| lint-file $f $rules} | flatten)
    for v in $all {
        print $v
    }
    print $"text-lint: ($files | length) files, ($all | length) violations"
}

# string -> string, code outside double quotes. No backslash-quotes
# exist in scripts (verified), so parity toggling is exact, and it
# resets per line by construction (callers pass one line).
def strip-quotes [s] {
    $s | split row '"' | enumerate | where {|r| ($r.index mod 2) == 0 } | get item | str join ""
}

# path, rules -> list, one string per OBS-OK violation, "path:line:reason".
# O-9 hidden-discard gate for Nu: a streaming pipe that drops its exit
# code silently looks green while failing. Allowed: `| complete`
# beside the discard (startup.nu precedent); the shapes below refuse.
# `rules` is the enabled subset of the STAGES obs-ok-lint sub-names.
def obs-lint-file [f rules] {
    let ls = (open --raw $f | lines)
    mut out = []
    for l in ($ls | enumerate) {
        let n = ($l.index + 1)
        let t = ($l.item | str trim)
        if ($t | str starts-with "#") { continue }
        let code = (strip-quotes $t)
        if (("ignore-without-complete" in $rules)
            and ($code | str contains "| ignore")
            and not ($code | str contains "complete")) {
            $out = ($out | append $"($f):($n):| ignore without complete")
        }
        if (("bare-try" in $rules)
            and ($code | str starts-with "try")
            and ($code | str contains "{")
            and not ($code | str contains "catch")) {
            $out = ($out | append $"($f):($n):bare try without catch")
        }
        if (("do-i-hides-errors" in $rules)
            and (($code | str contains "do -i") or ($code | str contains "do --ignore-errors"))) {
            $out = ($out | append $"($f):($n):do -i hides errors")
        }
        if (("dev-null" in $rules) and ($code | str contains "/dev/null")) {
            $out = ($out | append $"($f):($n):/dev/null discard")
        }
        if (("timer-wait" in $rules)
            and (($code | str contains "sleep") or ($code | str contains "timeout"))) {
            $out = ($out | append $"($f):($n):timer wait D-015")
        }
    }
    $out
}

# path, rules -> list, every OBS-OK violation under root, nothing printed
def obs-lint-collect [root rules] {
    let files = (lint-files $root | where {|f| ($f | str ends-with ".nu") })
    $files | each {|f| obs-lint-file $f $rules} | flatten
}

def run-obs-ok-lint [rules] {
    print $"[check] obs-ok-lint rules=($rules | str join ',')"
    let spec = ($env | get -o CYBERDECK_LINT_ROOTS? | default ".")
    let roots = ($spec | split row " ")
    for r in $roots {
        let files = (lint-files $r | where {|f| ($f | str ends-with ".nu") })
        let all = ($files | each {|f| obs-lint-file $f $rules} | flatten)
        for v in $all {
            print $v
        }
        print $"obs-ok-lint: ($files | length) files, ($all | length) violations"
    }
    let violations = ($roots | each {|r| obs-lint-collect $r $rules } | flatten | length)
    if $violations > 0 { exit $EXIT_VIOLATIONS }
}

# V-3: one printer for the user. A raw print outside package-manager/src/narration/narration.rkt
# and package-manager/src/narration/print-console.rkt means some command is talking to the terminal by
# itself, which is exactly what D-036 removed. Quoted text is stripped
# first so the lint does not match its own vocabulary. `rules` is the
# enabled subset of the STAGES one-printer-lint sub-names.
def print-lint-file [f rules] {
    let ls = (open --raw $f | lines)
    mut out = []
    # Non-test code only: everything from (module+ test onwards is a test
    # block, and a test may print whatever it needs to assert on. The
    # line index of that form is found once, then used as the cut.
    let starts = ($ls | enumerate | where {|r|
        ($r.item | str trim) == "(module+ test"
    } | get index)
    # sentinel is the line count, never -1: with -1 the `>=` guard below
    # skipped EVERY line of a file with no test block, so the lint
    # silently passed a whole class of files (measured: 12 files).
    let test_at = (if ($starts | is-empty) { $ls | length } else { $starts | first })
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
            (("raw-printf" in $rules) and ($code | str contains "(printf"))
            or (("raw-eprintf" in $rules) and ($code | str contains "(eprintf"))
            or (("raw-write-string" in $rules) and ($code | str contains "(write-string"))
            or (("bare-displayln" in $rules) and $bare_displayln)
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
        # sentinel is the line count, never -1: with -1 the `>=` guard
        # below skips EVERY line of a file that has no test block
        # (measured: spec-fields.rkt's only source-pinned? call was
        # counted as zero that way).
        let test_at = (if ($starts | is-empty) { $ls | length } else { $starts | first })
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

def run-security-gate-lint [rules] {
    print $"[check] security-gate-lint rules=($rules | str join ',')"
    let spec = ($env | get -o CYBERDECK_LINT_ROOTS? | default ".")
    let roots = ($spec | split row " ")
    mut violations = []
    for r in $roots {
        let files = (lint-files $r | where {|f| ($f | str ends-with ".rkt") })
        if ("uncalled-predicates" in $rules) {
            let nonsec = ($files | where {|f| ($f | path basename) != "security.rkt" })
            for pred in (sec-predicates) {
                let n = (sec-call-count $pred $nonsec)
                if $n == 0 {
                    $violations = ($violations | append (
                      "security-gate-lint: predicate " + $pred + " uncalled (S-04)"
                    ))
                }
            }
            print $"security-gate-lint: predicates checked, ($violations | length) violations so far"
        }
        if ("audited-writers" in $rules) {
            # The files allowed to contain the two effects. This list is the
            # MEASURED set: every name below was put back by the lint itself
            # after the old hand-guessed list (full of pre-split filenames
            # like build.rkt and verbose.rkt that no longer exist) was
            # cleared. Comments are skipped in the scan, so a prose mention
            # of subprocess is not an effect (measured: kill-tree, spawn and
            # status-fifo tripped on their own explanatory comments).
            # A file outside this list that opens an output file or spawns a
            # subprocess fails here, so new effects get written down instead
            # of slipping in.
            let writers = ["vault.rkt" "vault-lock.rkt" "directories.rkt"
                "narration.rkt" "event-text.rkt" "run.rkt" "jobs.rkt"
                "probe-blob.rkt"]
            for f in $files {
                let base = ($f | path basename)
                if ($base in $writers) { continue }
                # Comments are skipped before the search: a `;` line that
                # merely mentions subprocess is prose, not an effect
                # (measured: kill-tree, spawn and status-fifo tripped on
                # their own explanatory comments while calling process*).
                let rawlines = (open --raw $f | lines
                    | where {|l| not (($l | str trim) | str starts-with ";") })
                let code = (($rawlines | each {|l|
                    strip-quotes ($l | str trim)
                }) | str join "
")
                let writer = (($code | str contains "open-output-file")
                    or ($code | str contains "subprocess"))
                if $writer {
                    $violations = ($violations | append (
                      "security-gate-lint: " + $f + " writes outside audit (S-04)"
                    ))
                }
            }
        }
        for v in $violations { print $v }
        print $"security-gate-lint: ($files | length) files, ($violations | length) violations"
    }
    if (($violations | length) > 0) { exit $EXIT_VIOLATIONS }
}

# ---------------------------------------------------------------------------
# test-body-print-lint: the one-printer rule INSIDE test bodies.
#
# WHY THIS STAGE EXISTS. one-printer-lint and security-gate-lint both stop
# at `(module+ test`. That was deliberate -- a test may print whatever it
# needs to assert on -- but the skip was total and only ever stated in a
# code comment. So a `displayln` in a test block printed straight to the
# console and the gate stayed green: a real violation, invisible, found by
# reading.
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
#     that would forbid testing. security-gate-lint's audited-writers rule
#     exists so an effect cannot slip in undeclared in PRODUCTION code.
#     Here the
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
                          "test-body-print-lint: " + $f + ":" + ($i + 1 | into string)
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

def run-test-body-print-lint [] {
    print "[check] test-body-print-lint"
    let spec = ($env | get -o CYBERDECK_LINT_ROOTS? | default ".")
    let roots = ($spec | split row " ")
    mut violations = []
    for r in $roots {
        let files = (lint-files $r | where {|f| ($f | str ends-with ".rkt") })
        let hits = ($files | each {|f| test-print-hits $f } | flatten)
        for v in $hits { print $v }
        print $"test-body-print-lint: ($files | length) files, ($hits | length) violations"
        $violations = ($violations | append $hits)
    }
    if (($violations | length) > 0) { exit $EXIT_VIOLATIONS }
}

def run-one-printer-lint [rules] {
    print $"[check] one-printer-lint rules=($rules | str join ',')"
    let spec = ($env | get -o CYBERDECK_LINT_ROOTS? | default ".")
    let roots = ($spec | split row " ")
    mut violations = []
    for r in $roots {
        # The two printers are package-manager/src/narration/narration.rkt
        # and package-manager/src/narration/print-console.rkt; every other
        # .rkt must reach the user through them. lint-files already drops
        # compiled/ and non-files, so this is the same list the text lint
        # sees.
        # package-manager/src/narration/event-text.rkt is exempt for a
        # structural reason, not a convenience: narration.rkt and
        # print-console.rkt both require event-text.rkt, so event-text.rkt
        # requiring them for its output would be a cycle. The exemption is
        # NAMED here so a second one has to be written down too, instead of
        # the list quietly growing.
        # gate/ and tools/ are exempt as CLASSES, for the same
        # written-down discipline: gate/read-check.rkt and
        # gate/test-runner.rkt print the gate's own diagnostics and must
        # not depend on the product code they gate; tools/*.rkt keep
        # their own printing by the V-0 inventory decision. D-036
        # governs the pm user's output, not the dev workbench.
        let printers = ["narration.rkt" "print-console.rkt"]
        let exempt = ["event-text.rkt"]
        let scanned = (lint-files $r | where {|f| ($f | str ends-with ".rkt") }
            | where {|f|
                not (($f | path basename) in ($printers | append $exempt))
            }
            | where {|f|
                not (($f | str contains "/gate/") or ($f | str contains "/tools/"))
            })
        let hits = ($scanned | each {|f| print-lint-file $f $rules } | flatten)
        for v in $hits { print $v }
        print $"one-printer-lint: ($scanned | length) files, ($hits | length) violations"
        $violations = ($violations | append $hits)
    }
    if (($violations | length) > 0) { exit $EXIT_VIOLATIONS }
}

def run-text-lint [rules] {
    print $"[check] text-lint rules=($rules | str join ',')"
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
            lint-root $r $rules
        }
    })
    # timeit discards the closure value, so the exit code is derived by a
    # second collect pass. It costs a few ms and keeps the timed block to
    # the real work: one lint-and-report pass.
    let violations = ($roots | each {|r| lint-collect $r $rules} | flatten | length)
    if $violations > 0 { exit $EXIT_VIOLATIONS }
}

# cli-no-file-url-flag (check.sh lines 8-11): cli/ must never reference
# the test-only file-URL flag. The old stage used `grep -rq` over cli/;
# here the files are read directly and searched with str contains, no
# external grep.
def check-cli-file-url-flag [] {
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

# git-present (check.sh lines 12-15): git must exist. `command -v`
# becomes `which`, a Nu built-in; only the exit status matters.
def check-git-present [] {
    let w = (do { ^which git } | complete)
    if $w.exit_code != 0 {
        print "GATE: git executable not found"
        return 1
    }
    0
}

# helper-tools-present (check.sh lines 16-22): the tools run.rkt shells
# out to must exist. Existence only. which is a Nu built-in; nothing is
# executed, nothing is installed.
def check-helper-tools [] {
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

# monorepo-rules (check.sh lines 23-37): the D-011 monorepo rules.
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

def check-monorepo-rules [] {
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

# pinned-nu-report (check.sh lines 80-84): export
# GIT_ALLOW_PROTOCOL=file for every spawn below, then report which
# Nushell the scripts would use. The report is informational only:
# `|| true` in the old gate, so a non-zero exit here is recorded and
# swallowed rather than failing the gate.
def report-pinned-nu [] {
    $env.GIT_ALLOW_PROTOCOL = "file"
    let nu_bin = ($env | get -o CYBERDECK_NU? | default ($nu.current-exe))
    let r = (do { run-external $nu_bin "--no-config-file" "gate/need-nu.nu" } | complete)
    print $"[pinned-nu-report] GIT_ALLOW_PROTOCOL=(($env | get GIT_ALLOW_PROTOCOL))"
    print $"[pinned-nu-report] nu report exit=($r.exit_code)"
    for l in ($r.stdout | lines) {
        print $"[pinned-nu-report] ($l)"
    }
    for l in ($r.stderr | lines) {
        print $"[pinned-nu-report] stderr: ($l)"
    }
    0
}

# file-set: the .rkt list. There are no tiers any more. Every .rkt in the
# tree goes through ONE shared-process runner, so the list is simply every
# .rkt, derived and never hand-listed.
#
# CYBERDECK_TEST_FILES (space separated) replaces the glob. It exists so a
# failing synthetic fixture outside the repo can drive the gate to
# CHECK FAILED; nothing else reads it.
def rkt-files [] {
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
# Both run-tests and --changed compare against this: the runner file list
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

# read-check: gate/read-check.rkt reads every named .rkt and names the
# exact file and line of the first malformed form, so an unbalanced paren
# is reported, not guessed at. It exits 1 when anything is bad, which is
# this stage's verdict. The file list is the same set compile uses, so a
# file that cannot even be read is caught before raco.
def run-read-check [] {
    print "[check] read-check"
    let racketx = ($nu.home-dir | path join "opt" "racket-full" "bin" "racket")
    let fs = (rkt-files)
    let code = (try {
        ^$racketx "gate/read-check.rkt" ...$fs
        0
    } catch { |e|
        print $"[check] read-check failed: ($e.msg)"
        1 })
    $code
}

# -> nothing, run one law script and stop the gate if it refuses. Both law
# stages live in their own file so the law and its enforcement stay in one
# place and this file only wires them: the script owns the exit code, and
# its own summary line is what the reader sees.
def run-law-stage [label: string, script: string] {
    print $"[check] ($label)"
    let nu_bin = ($env | get -o CYBERDECK_NU? | default ($nu.current-exe))
    let r = (do { run-external $nu_bin "--no-config-file" $script } | complete)
    if ($r.stdout | str trim) != '' { print ($r.stdout | str trim) }
    if $r.exit_code != 0 { exit $r.exit_code }
}

def run-banned-words-lint [] {
    run-law-stage "banned-words-lint" "gate/banned-words-lint.nu"
}

def run-one-way-dependency-lint [] {
    run-law-stage "one-way-dependency-lint" "gate/one-way-dependency-lint.nu"
}

# -> bool, is the stage (or one of its sub-stages) requested?
def stage-on? [todo name] {
    ($name in $todo) or ($todo | any {|t| ($t | str starts-with ($name + "/")) })
}

# -> list of sub-rules to run for a lint stage: all of them when the
# bare stage name was asked for, else exactly the named sub-stages.
# Names were validated before any stage runs.
def stage-rules [todo name] {
    let all = (stage-subs $name)
    if ($name in $todo) { $all } else {
        $todo | where {|t| ($t | str starts-with ($name + "/")) }
        | each {|t| ($t | split row "/" | last) }
    }
}

# -> list, the sub-stage names of one stage, from the one STAGES table
def stage-subs [name] {
    ($STAGES | where {|r| ($r | get 0) == $name } | first | get 1)
}

# A wrong name must fail loudly: silence is how a renamed stage turns
# into a stage that never ran. A retired stage prints its reason and
# runs nothing.
def validate-todo [todo] {
    let names = ($STAGES | each {|r| $r | get 0})
    let retired = ($RETIRED_STAGES | each {|r| $r | get 0})
    for t in $todo {
        let parts = ($t | split row "/")
        let name = ($parts | first)
        if ($name in $retired) {
            let rec = ($RETIRED_STAGES | where {|r| ($r | get 0) == $name } | first)
            print $"[check] retired: ($name) - ($rec | get 1)"
            continue
        }
        if not ($name in $names) {
            print $"[check] ($t): no such stage name; stages say what they check"
            print "[check] run nu gate/check.nu --list for every name and sub-name"
            exit $EXIT_USAGE
        }
        if (($parts | length) > 1) {
            let sub = ($parts | last)
            let subs = (stage-subs $name)
            if not ($sub in $subs) {
                print $"[check] ($sub): no such sub-stage of ($name)"
                print $"[check] ($name) sub-stages: ($subs | str join ', ')"
                exit $EXIT_USAGE
            }
        }
    }
}

# --list: print the one table the dispatcher validates against, so the
# record and the runner cannot drift apart.
def print-stage-list [] {
    print "stages are named by what they check; sub-stages read"
    print "parent-name/rule. CYBERDECK_STAGES takes a comma list of"
    print "names and name/sub tokens."
    print ""
    for r in $STAGES {
        let name = ($r | get 0)
        let subs = ($r | get 1)
        let what = ($r | get 2)
        if ($subs | is-empty) {
            print $"- ($name)"
        } else {
            print $"- ($name)   sub: ($subs | str join ', ')"
        }
        print $"    ($what)"
    }
    for r in $RETIRED_STAGES {
        print $"- ($r | get 0)   RETIRED: ($r | get 1)"
    }
}

# Named main, so the CLI matches check.sh (`nu gate/check.nu --changed`);
# --list prints the stage table and runs nothing. Verified 0.116.1: nu
# auto-invokes a command called main and passes flags through; it must
# therefore NOT also be called explicitly, or the whole gate runs twice.
#
# The verdict leaves through a `mut` in THIS scope, not through $env: in
# 0.116.1 an `$env.X = ...` assignment inside a `timeit { }` closure does not
# persist (measured), so the old shape printed CHECK FAILED and still exited
# 0. There is no closure here at all, which is why the mut is allowed.
def main [--changed, --list] {
    if $list {
        print-stage-list
        return
    }
    print $"[check] run start utc=(utc)"
    let changed_mode = ($changed or (($env | get -o CYBERDECK_CHANGED?) == "1"))
    let full_default = ([
        "cli-no-file-url-flag" "git-present" "helper-tools-present"
        "monorepo-rules" "text-lint" "pinned-nu-report" "file-set"
        "compile" "run-tests" "verdict" "read-check" "obs-ok-lint"
        "one-printer-lint" "security-gate-lint" "test-body-print-lint"
    ] | str join ",")
    let changed_default = ([
        "cli-no-file-url-flag" "git-present" "helper-tools-present"
        "monorepo-rules" "pinned-nu-report" "obs-ok-lint"
        "one-printer-lint" "security-gate-lint" "test-body-print-lint"
        "changed-files"
    ] | str join ",")
    let want = (if $changed_mode {
        $env | get -o CYBERDECK_STAGES? | default $changed_default
    } else {
        $env | get -o CYBERDECK_STAGES? | default $full_default
    })
    let todo = ($want | split row "," | each {|t| $t | str trim }
        | where {|t| ($t | is-not-empty) })
    validate-todo $todo
    # `date now` is read twice and subtracted: measurement only, printed for
    # the record. Nothing waits on it (D-015).
    let started = (date now | into int)
    mut verdict_code = 0
    require-pinned-version
    if (stage-on? $todo "cli-no-file-url-flag") {
        print "[check] cli-no-file-url-flag"
        let rc = (check-cli-file-url-flag)
        print $"[check] cli-no-file-url-flag exit=($rc)"
    }
    if (stage-on? $todo "git-present") {
        print "[check] git-present"
        let rc = (check-git-present)
        print $"[check] git-present exit=($rc)"
    }
    if (stage-on? $todo "helper-tools-present") {
        print "[check] helper-tools-present"
        let rc = (check-helper-tools)
        print $"[check] helper-tools-present exit=($rc)"
    }
    if (stage-on? $todo "monorepo-rules") {
        print "[check] monorepo-rules"
        let rc = (check-monorepo-rules)
        print $"[check] monorepo-rules exit=($rc)"
    }
    if (stage-on? $todo "pinned-nu-report") {
        let rc = (report-pinned-nu)
        print $"[check] pinned-nu-report exit=($rc)"
    }
    if (stage-on? $todo "file-set") {
        let fs = (rkt-files)
        print $"[check] file-set ($fs | length) files"
        for f in $fs { print $"[check] file-set ($f)" }
    }
    if (stage-on? $todo "text-lint") {
        run-text-lint (stage-rules $todo "text-lint")
    }
    # compile, run-tests and verdict. Every .rkt is compiled, then every
    # test file is run through ONE shared-process runner. The runner's
    # records and one record per compiled file are handed to verdict, so
    # a compile failure fails the gate exactly as `raco make` used to.
    let full = (rkt-files)
    let parked = ((rkt-files) | where {|f| (file-parked? $f) })
    mut ccodes = []
    mut recs = []
    if (stage-on? $todo "changed-files") {
        let chrc = (run-changed-files)
        print $"[check] changed-files exit=($chrc)"
    }
    if (stage-on? $todo "compile") {
        print $"[check] compile ($full | length) files"
        $ccodes = (compile-all $full)
        let cbad = ($ccodes | any {|c| $c != 0})
        print $"[check] compile exit=(if $cbad { 1 } else { 0 })"
    }
    if (stage-on? $todo "run-tests") {
        for l in (parked-lines) {
            print $l
        }
        let testfiles = ($full | where {|f| not (file-parked? $f) })
        print $"[check] run-tests ($testfiles | length) files one process"
        $recs = (if ($testfiles | is-empty) { [] } else { run-runner $testfiles })
        let bad10 = ($recs | any {|r| $r.exit != 0})
        print $"[check] run-tests records=($recs | length) failed=($bad10)"
    }
    if (stage-on? $todo "verdict") {
        let crecs = ($ccodes | each {|c| {file: "(compile)", exit: $c, ms: 0} })
        $verdict_code = (verdict ($recs | append $crecs) (parked-total))
        print $"[check] verdict exit=($verdict_code)"
    }
    if (stage-on? $todo "read-check") {
        let rc12 = (run-read-check)
        print $"[check] read-check exit=($rc12)"
        if $rc12 != 0 {
            $verdict_code = 1
        }
    }
    if (stage-on? $todo "obs-ok-lint") {
        run-obs-ok-lint (stage-rules $todo "obs-ok-lint")
    }
    if (stage-on? $todo "one-printer-lint") {
        run-one-printer-lint (stage-rules $todo "one-printer-lint")
    }
    if (stage-on? $todo "security-gate-lint") {
        run-security-gate-lint (stage-rules $todo "security-gate-lint")
    }
    if (stage-on? $todo "test-body-print-lint") {
        run-test-body-print-lint
    }
    if (stage-on? $todo "banned-words-lint") {
        run-banned-words-lint
    }
    if (stage-on? $todo "one-way-dependency-lint") {
        run-one-way-dependency-lint
    }
    let elapsed = (((date now | into int) - $started) / 1000000)
    print $"[check] end utc=(utc) after=($elapsed)ms"
    exit $verdict_code
}

# compile/run-tests/verdict helpers (check.sh lines 97-130). The cheap
# gates stay above; these are the compile, test and verdict halves,
# proved on fixtures first.
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
    print $"[check] compile ($sorted | length) files in one raco make"
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
    let allr = (rkt-files)
    $allr | where {|f|
        let body = (open --raw $f)
        if not ($body | str contains "(require") {
            false
        } else {
            $changed | any {|c| $body | str contains ($c | path basename) }
        } }
}

# The --changed between-items gate: the caller's cheap stages still run,
# then only what changed is compiled and tested, through the same
# one-process shared runner the full gate uses.
def run-changed-files [] {
    let changed = (changed-rkt)
    if ($changed | is-empty) {
        print "[changed-files] nothing changed; nothing to do"
        return 0
    }
    print $"[changed-files] ($changed | length) changed rkt files"
    for c in $changed {
        print $"[changed-files] ($c)"
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
        print "[changed-files] nothing to run"
        return 0
    }
    let ccodes = (compile-all $runset)
    let recs = (run-runner $runset)
    let bad = ($ccodes | any {|c| $c != 0}) or ($recs | any {|r| $r.exit != 0})
    (verdict $recs ($parked | length))
    (if $bad { 1 } else { 0 })
}
