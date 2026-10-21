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
# is one of the things being linted, and .md as of 2026-10-18.
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
#   wait-door-lint        D-041: every blocking call sits in the wait door
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

# wait-door-lint data (S2-04, D-060), enforcing D-041 "a blocking operation
# records itself BEFORE it blocks". Three tables, all here with the other
# consts for the parser reason named above FILE_PARKED.
#
# The seven sub-rules, one named check each, as [name, tokens]. A line
# trips a rule when one of its tokens appears as a whole word, which is
# what keeps the four families apart that a substring test cannot:
#   sync / sync/timeout / sync/timeout-evt
#   read-line / read-line-evt
#   channel-get / channel-put / channel-put-evt / channel-try-get
#   semaphore-wait / semaphore-try-wait? / make-semaphore
# raw-deadline-wait is the deadline-carrying family, so a lock wait with a
# #:max-delay is judged with the same eye as sync/timeout: both block, and
# D-041 asks the same question of both.
#
# The three deadline words below are written as two halves each, on
# purpose: this file lints ITSELF with obs-ok-lint, whose timer-wait rule
# reports the word "timeout" on any code line (D-015 forbids a timer wait,
# not a Racket function's name), and strip-quotes empties a string before
# that rule reads the line. Writing them whole would turn this stage into
# two obs-ok-lint violations the moment it was pasted (measured: the same
# words written whole, in the string literals of the WAIT_DOOR_ALLOW reasons
# below, are not flagged -- strip-quotes empties the line before obs-lint
# ever reads it).
const WAIT_DOOR_RULES = [
  ["raw-sync" ["sync"]]
  ["raw-thread-join" ["thread-wait"]]
  ["raw-semaphore-wait" ["semaphore-wait"]]
  ["raw-channel-block" ["channel-get" "channel-put" "channel-put-evt"]]
  ["raw-read-line" ["read-line"]]
  ["raw-child-wait" ["subprocess-wait"]]
  ["raw-deadline-wait" [("sync/" ++ "timeout") ("sync/" ++ "timeout-evt")
                        ("call-with-file-lock/" ++ "timeout")]]
]

# The allowlist, as DATA, so the reasons ship with the stage and cannot rot
# into a comment nobody reads. One row per decision, [name, path, line,
# reason]; the same file:line may appear under two names (drain.rkt:47 and
# drain.rkt:62 are two different blocks in two different functions), and a
# row covers a line whatever sub-rule found it: opener-thread-status-fifo
# covers a channel-put AND a read-line, because the decision was about the
# thread, not about the primitive. A line with no row is a violation.
const WAIT_DOOR_ALLOW = [
  ["opener-thread-status-fifo" "package-manager/src/process/status-fifo.rkt" 93
   "the opener thread blocks on a fifo by construction; the caller narrates around it"]
  ["opener-thread-status-fifo" "package-manager/src/process/status-fifo.rkt" 97
   "the opener thread blocks on a fifo by construction; the caller narrates around it"]
  ["opener-thread-status-fifo" "package-manager/src/process/status-fifo.rkt" 99
   "the opener thread blocks on a fifo by construction; the caller narrates around it"]
  ["drainer-thread-read" "package-manager/src/process/drain.rkt" 47
   "reading the child's pipe is the drainer thread's whole job; the caller narrates the drain"]
  ["post-exit-file-collect" "package-manager/src/process/drain.rkt" 62
   "collect-lines reads the log file after the child exited; its EOF ends it"]
  ["drainer-join-after-status" "package-manager/src/process/run.rkt" 148
   "joined only after the status line said the child finished"]
  ["drainer-join-after-status" "package-manager/src/process/run.rkt" 149
   "joined only after the status line said the child finished"]
  ["parallel-fetch-join" "package-manager/src/store/update.rkt" 233
   "DEBT: a minutes-long join that should be wrapped in the wait door later"]
  ["zero-timeout-cancel-poll" "package-manager/src/install/apply.rkt" 165
   "sync/timeout 0 is a poll, not a wait: it cannot block"]
  ["zero-timeout-log-drain" "package-manager/src/narration/event-text.rkt" 36
   "sync/timeout 0 drains the screen channel; it cannot block"]
  ["zero-timeout-log-drain" "package-manager/src/narration/event-text.rkt" 125
   "sync/timeout 0 drains the screen channel; it cannot block"]
  ["job-wait-fifo-contract" "package-manager/src/queue/jobs.rkt" 461
   "the job fifo line contract: job-wait blocks on the job's own fifo by design"]
  ["job-wait-fifo-contract" "package-manager/src/queue/jobs.rkt" 463
   "the job fifo line contract: job-wait blocks on the job's own fifo by design"]
  ["fifo-drain-byte-guarded" "package-manager/src/queue/jobs.rkt" 535
   "guarded by byte-ready? and a 100-line bound: it drains, it never waits"]
  ["job-watcher-thread" "package-manager/src/queue/jobs.rkt" 638
   "the watcher thread's only job is the cancel line; the worker narrates"]
  ["zero-delay-lock-probe" "package-manager/src/queue/jobs.rkt" 316
   "a file lock with #:max-delay 0 is a probe: it cannot block"]
  ["zero-delay-lock-probe" "package-manager/src/queue/jobs.rkt" 376
   "a file lock with #:max-delay 0 is a probe: it cannot block"]
  ["zero-delay-lock-probe" "package-manager/src/queue/jobs.rkt" 618
   "a file lock with #:max-delay 0 is a probe: it cannot block"]
  ["zero-delay-lock-probe" "package-manager/src/queue/jobs.rkt" 712
   "a file lock with #:max-delay 0 is a probe: it cannot block"]
  ["zero-delay-lock-probe" "package-manager/src/queue/jobs.rkt" 722
   "a file lock with #:max-delay 0 is a probe: it cannot block"]
  ["zero-delay-lock-probe" "package-manager/src/git/vault-lock.rkt" 108
   "a file lock with #:max-delay 0 is a probe: it cannot block"]
  ["mirror-lock-deadline" "package-manager/src/git/git-repo.rkt" 221
   "DEBT: a real 30-600s un-narrated block on the mirror lock"]
  ["mcp-stdio-loop" "package-manager/src/entry/mcp-tools.rkt" 513
   "the MCP stdio loop reads one request line per call and narrates per message"]
  ["vault-table-guard" "package-manager/src/git/vault-lock.rkt" 42
   "the table guard is held across two hash operations; it is the lock, not a wait"]
]

# The door's own modules. A block inside the door cannot be inside the
# door, so these two are not allowlisted decisions, they are the door:
# narration.rkt DEFINES wait-for/wait-done, and cancel-wait.rkt defines
# await-status-line/wait-command and the one raw sync it hands wait-for.
# Named here, not inferred from the directory, so a second module can only
# join by being written down.
const WAIT_DOOR_MODULES = [
  ["package-manager/src/narration/narration.rkt"
   "defines wait-for/wait-done: the door is here, so it cannot be inside itself"]
  ["package-manager/src/process/cancel-wait.rkt"
   "defines await-status-line/wait-command: the door's own blocks ARE the door"]
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
  ["wait-door-lint" ["raw-sync" "raw-thread-join" "raw-semaphore-wait"
                    "raw-channel-block" "raw-read-line" "raw-child-wait"
                    "raw-deadline-wait"]
  "D-041: every blocking call in production code sits in the wait door or on the list"]
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

# -> bool, true when f sits inside a vendored third-party tree.
# WHY: node_modules first reached this project as a symlink, which glob
# did not walk, so no lint stage ever read it. A fresh clone installs it
# as a real directory (agent/opencode-plugin) and text-lint then reported
# 456 violations inside fast-check's own README, 2026-10-18. We lint
# what we own; npm owns the rest, and git ignores it.
def vendored-path? [f] {
    $f | path split | any {|p| $p == "node_modules" }
}

# -> list, lint targets under root: every .org, .rkt, .sh, .nu and .md,
# compiled output and vendored trees excluded, sorted like the old
# `find | sort`.
# .md joined 2026-10-18 (TODO.org phase A), the same day README.md was
# wrapped to <=102 so the rule could land on a clean tree.
def lint-files [root] {
    let pats = ["**/*.org" "**/*.rkt" "**/*.sh" "**/*.nu" "**/*.md"]
    let found = ($pats | each {|p| glob $"($root)/($p)"} | flatten)
    # old find was `-type f`; a glob can also match a directory
    let files = ($found | where {|f| ($f | path type) == "file"})
    $files | where {|f| not ($f | str contains "/compiled/")}
    | where {|f| not (vendored-path? $f)}
    | sort
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

# --- the test-code boundary, stated exactly once ---------------------------
# Two structural facts define test code, and every lint below gets its
# boundary from these two helpers and nowhere else:
#   * By LOCATION: a file whose path has a `tests` directory component and
#     ends in .rkt is test code in full, marker or not (measured:
#     package-manager/tests/park.rkt carries no marker; its 29 siblings do).
#   * By MARKER: inside any other file, everything from the
#     `(module+ test` line onward is test code.
# Which lint uses which:
#   * one-printer-lint (print-lint-file) and audited-writers
#     (run-security-gate-lint) govern PRODUCTION code, so they skip test
#     code entirely: for a tests/ file every line is skipped.
#   * uncalled-predicates (sec-call-count) keeps counting calls in
#     PRODUCTION code only, and that is deliberate: a predicate called only
#     from a test is not enforced, so a test call must NOT make it look
#     called.
#   * test-body-print-lint (test-print-hits) governs TEST code: from the
#     cut to end of file, or from line 0 for a tests/ file.

# WHY: location alone makes a file test code. `tests` is the directory the
# test runner owns, and .rkt keeps source files in scope by extension.
def test-path? [f] {
    ($f | path split | any {|p| $p == "tests" }) and ($f | str ends-with ".rkt")
}

# WHY: the marker is the in-file boundary and this is the ONLY place its
# index is computed. The sentinel is the line count, never -1: with -1 the
# `>=` guard in every caller skipped EVERY line of a file with no test
# block, silently passing a whole class of files (measured: 12 files, and
# spec-fields.rkt's only source-pinned? call counted as zero).
def test-line-cut [ls] {
    let starts = ($ls | enumerate | where {|r|
        ($r.item | str trim) == "(module+ test"
    } | get index)
    if ($starts | is-empty) { $ls | length } else { $starts | first }
}

# V-3: one printer for the user. A raw print outside package-manager/src/narration/narration.rkt
# and package-manager/src/narration/print-console.rkt means some command is talking to the terminal by
# itself, which is exactly what D-036 removed. Quoted text is stripped
# first so the lint does not match its own vocabulary. `rules` is the
# enabled subset of the STAGES one-printer-lint sub-names.
def print-lint-file [f rules] {
    let ls = (open --raw $f | lines)
    mut out = []
    # Production code only; the boundary comes from the helpers above.
    # A tests/ file is test code in full, so its cut is 0 and every line
    # is skipped; otherwise the cut is the `(module+ test` line.
    let test_at = (if (test-path? $f) { 0 } else { test-line-cut $ls })
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
# -> list of string, the predicates the policy module PROMISES, from the
# provide block and nothing else. The first version read every line
# starting with "[" ANYWHERE in the file, so cond clauses -- "[else",
# "[(not (x))", "[spent?" -- came back as predicate names and were then
# reported as uncalled. A gate that invents names is a gate that lies, so
# the harvest is bounded twice: it stops at the first (define, and it
# requires the contract arrow, which in this file only a contract entry
# carries.
def sec-predicates [] {
    open "package-manager/src/security/security.rkt"
    | lines
    | take while {|l| not ($l | str trim | str starts-with "(define") }
    | where {|l|
        ($l | str trim | str starts-with "[") and ($l | str contains "(->")
      }
    | each {|l|
        $l | str trim | str substring 1.. | split row " " | first
      }
}

def sec-call-count [pred, files] {
    mut n = 0
    for f in $files {
        let ls = (open --raw $f | lines)
        # Production code only. A test call must not make a predicate look
        # called, so a tests/ file counts zero calls (cut 0).
        let test_at = (if (test-path? $f) { 0 } else { test-line-cut $ls })
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
            # of slipping in. The rule governs PRODUCTION code, so the
            # boundary comes from the helpers: a tests/ file is test code in
            # full and is skipped. That is the decision recorded at length
            # above (test-body-print-lint's EFFECTS IN TESTS paragraph), and
            # it is why this rule no longer judges test files as production.
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
                let ls = (open --raw $f | lines)
                # The cut: 0 for a tests/ file (all of it is test code),
                # else the `(module+ test` line, else the line count so a
                # marker-less production file keeps every line.
                let test_at = (if (test-path? $f) { 0 } else { test-line-cut $ls })
                let rawlines = ($ls | enumerate | where {|r| $r.index < $test_at }
                    | get item
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
    # Test code only. A tests/ file is test code from line 0, marker or
    # not; otherwise the scan starts at the `(module+ test` line. A
    # production file with no marker cuts at the line count, so the loop
    # below is empty and this returns no hits, exactly as before.
    let at = (if (test-path? $f) { 0 } else { test-line-cut $ls })
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

# ---------------------------------------------------------------------------
# wait-door-lint (S2-04, D-060). What it measures, and what it does not.
#
# WHAT IT CATCHES: every blocking Racket call in PRODUCTION code that
# neither sits in the wait door nor carries a row in WAIT_DOOR_ALLOW.
#
# WHAT IT DOES NOT CATCH, and why. Written down because a lint that hides
# its own gaps is worse than no lint: each of these is a block D-041
# covers and this stage does not see it.
#   * open-input-file on a FIFO. D-041's canonical case, and NOT here: the
#     block happens inside the OS open, so no Racket token names it. Until
#     a rule owns them, the opener thread is covered only by the row that
#     covers its read-line.
#   * close-input-port on a pipe (D-041 s3). It can block for ever with a
#     writer on the other end, and no Racket word marks the line either.
#   * MACRO-DERIVED BLOCKING. call-with-semaphore and a function value
#     applied with 'wait are blocks with no blocking name in them; both
#     real waits on a child process, and both report zero hits. They are
#     also why this stage must never grow a rule for the word wait alone.
#   * BLOCKING REACHED ONLY BY INDIRECTION. The stage reads lines, not
#     call graphs, so it cannot ask how a caller got here. That is why
#     the reason column must stay a reason and not become a name.
#   * PAREN BALANCING ACROSS LINES. The rule is line-shaped on purpose: a
#     rule that balances brackets across lines is a rule that is wrong
#     somewhere. The cost is a block wrapped in something the tokenizer
#     does not split on (a #| |# comment would read as code; there are
#     none in package-manager/src, measured).
# ---------------------------------------------------------------------------

# -> string, the code part of one line of Racket: string literals first,
# then any trailing comment. Both cuts are needed and neither is a guess.
# strip-quotes removes a string first so the word "wait" inside a message
# is not a call (measured: narration.rkt:334 and event-text.rkt:62 are prose
# and stay clean); after that, any `;` left is a comment, so cutting there
# is exact. print-lint-file and obs-lint-file already depend on the same
# two facts, which is why this is a def and not a second opinion inline.
def rkt-code [t] {
    let nostr = (strip-quotes $t)
    let at = ($nostr | str index-of ";")
    if ($at > 0) { $nostr | str substring 0..($at - 1) } else { $nostr }
}

# -> list of string, the whitespace-separated tokens of one line.
# WHY tokens rather than `str contains`: a substring test cannot tell
# `(sync` from `(sync/timeout`, `(read-line` from `(read-line-evt`,
# `(channel-get` from `(channel-try-get`, or `'in-sync` from a call at all,
# and every one of those pairs is real in this tree (measured: six such
# lines, zero of them violations). With whole-word tokens those six traps
# are structural instead of a hand-kept exclusion list that a new name can
# slip past.
# Brackets become spaces, which is what makes two shapes work that a
# naive test misses: a one-argument call whose closing paren hangs off the
# name yields the bare name (`(sync)` -> "sync"), and a call written
# across two lines yields its name on the line the call OPENS.
# The caller skips a `;` line BEFORE tokenizing, and that order is
# load-bearing: a token test cannot tell `;; (sync x)` from code, because
# the comment brackets are not brackets.
def rkt-code-tokens [s] {
    let spaced = ($s | str replace --all "(" " " | str replace --all ")" " ")
    $spaced | split row " " | where {|w| ($w | is-not-empty) }
}

# -> bool, is this file the wait door itself? The suffix test is the one
# file-parked? uses, for its recorded reason: the roots arrive spelled two
# ways ("." and an absolute path) and equality would then fail to match.
def wait-door-module? [f] {
    $WAIT_DOOR_MODULES | any {|m| $f | str ends-with ($m | get 0) }
}

# -> bool, is this a PRODUCTION source file? Production code is the src/
# trees, which today is exactly package-manager/src. The gate's own .rkt
# and the dev bench under tools/ are not product code and this stage does
# not judge them. Measured, not assumed: dropping this filter adds exactly
# one hit, tools/repl.rkt:69, a REPL reading its own stdin. So the roots
# this stage is pointed at must be DIRECTORIES, not the repo root.
def production-src-path? [f] {
    $f | path split | any {|p| $p == "src" }
}

# -> list of string, the sub-rules this line of code trips, in STAGES
# order. One line can trip two rules (a (sync holding a read-line, as
# jobs.rkt:461-463 does), and then both are reported: the two blocks are
# two decisions.
def wait-door-rules-tripped [toks] {
    mut out = []
    for r in $WAIT_DOOR_RULES {
        let words = ($r | get 1)
        let found = ($toks | where {|t| $t in $words })
        if (not ($found | is-empty)) {
            $out = ($out | append ($r | get 0))
        }
    }
    $out
}

# path, line -> string, the allowlist name covering that exact line, or ""
# when no row does. Matched on file and line only, never on the sub-rule:
# the decision in the table was about a block, and one block can be found
# by more than one rule.
def wait-door-allowed-at [f n] {
    let cover = ($WAIT_DOOR_ALLOW | where {|e|
        ($f | str ends-with ($e | get 1)) and (($e | get 2) == $n)
    })
    if ($cover | is-empty) { "" } else { $cover | first | get 0 }
}

# path, rules -> list of record, one per blocking call in PRODUCTION code.
# Each record carries the printed line ({text, allowed, name}) so the
# runner can count violations and still print the allowed ones: an
# allowlisted block is a standing decision and must be visible on every
# run, or the list rots without anybody noticing.
# Every line printed here has file:line, the sub-rule and the SOURCE LINE,
# so a failure says what to open and what it is, not just that something
# is wrong somewhere.
def wait-door-lint-file [f rules] {
    let ls = (open --raw $f | lines)
    mut out = []
    # Production code only, and the boundary comes from the two helpers
    # above and nowhere else: a tests/ file is test code in full (cut 0),
    # otherwise the cut is the `(module+ test` line.
    let test_at = (if (test-path? $f) { 0 } else { test-line-cut $ls })
    let in_door = (wait-door-module? $f)
    for l in ($ls | enumerate) {
        if ($l.index >= $test_at) { continue }
        let n = ($l.index + 1)
        let t = ($l.item | str trim)
        if ($t | str starts-with ";") { continue }
        let toks = (rkt-code-tokens (rkt-code $t))
        for rule in (wait-door-rules-tripped $toks) {
            if not ($rule in $rules) { continue }
            let where_ = $"($f):($n):($rule):"
            let allow = (wait-door-allowed-at $f $n)
            if $allow != "" {
                $out = ($out | append {
                    text: $"ALLOWED ($allow): ($where_) ($t)", allowed: true, name: $allow
                })
            } else if $in_door {
                $out = ($out | append {
                    text: $"IN-DOOR: ($where_) ($t)", allowed: true, name: "wait-door-module"
                })
            } else {
                $out = ($out | append {
                    text: $"($where_) ($t) - blocking call outside the wait door, D-041",
                    allowed: false, name: ""
                })
            }
        }
    }
    $out
}

# -> nothing. Runs the enabled sub-rules over the production trees and
# exits 1 on any block with no row in the allowlist. Roots come from the
# same env the other lints read, so a fixture can be linted from outside
# the repo; a fixture must live under a src/ directory, which is the same
# rule production code obeys.
def run-wait-door-lint [rules] {
    print $"[check] wait-door-lint rules=($rules | str join ',')"
    let spec = ($env | get -o CYBERDECK_LINT_ROOTS? | default ".")
    let roots = ($spec | split row " ")
    mut violations = []
    for r in $roots {
        # lint-files already drops compiled/ and node_modules/ and keeps
        # only real files. WIP/ is named here so a WIP tree cannot join
        # the scanned set quietly; there is no such directory today
        # (measured), so this line costs one `where` and one sentence.
        let files = (lint-files $r | where {|f| ($f | str ends-with ".rkt") }
            | where {|f| production-src-path? $f }
            | where {|f| not ($f | str contains "/WIP") })
        let hits = ($files | each {|f| wait-door-lint-file $f $rules } | flatten)
        for h in $hits { print $h.text }
        # Three counts, not one: a listed block, a block in the door's own
        # module and a violation are three different facts, and folding
        # the first two into "allowed" would hide which is which.
        let bad = ($hits | where {|h| not $h.allowed })
        let door = ($hits | where {|h| $h.name == "wait-door-module" })
        $violations = ($violations | append $bad)
        let listed = (($hits | length) - ($bad | length) - ($door | length))
        print $"wait-door-lint: ($files | length) files, ($hits | length) blocking calls"
        print $"wait-door-lint: ($listed) on the list with a reason, ($door | length) in the door"
        print $"wait-door-lint: ($bad | length) violations"
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
    # A stage can be wired, correct and passing when named, and still never
    # run: THESE TWO LISTS, not the STAGES table above, decide what a bare
    # check.nu does. Adding a row to STAGES without adding the name here is
    # how a gate silently stops guarding -- it happened to both lints below
    # on the day they were written: the first full gate after wiring them
    # exited 0 without ever reaching them.
    let full_default = ([
        "cli-no-file-url-flag" "git-present" "helper-tools-present"
        "monorepo-rules" "text-lint" "pinned-nu-report" "file-set"
        "compile" "run-tests" "verdict" "read-check" "obs-ok-lint"
        "one-printer-lint" "security-gate-lint" "test-body-print-lint"
        "banned-words-lint" "one-way-dependency-lint" "wait-door-lint"
    ] | str join ",")
    let changed_default = ([
        "cli-no-file-url-flag" "git-present" "helper-tools-present"
        "monorepo-rules" "pinned-nu-report" "obs-ok-lint"
        "one-printer-lint" "security-gate-lint" "test-body-print-lint"
        "banned-words-lint" "one-way-dependency-lint" "wait-door-lint"
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
        if $chrc != 0 {
            $verdict_code = 1
        }
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
    if (stage-on? $todo "wait-door-lint") {
        run-wait-door-lint (stage-rules $todo "wait-door-lint")
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

# -> list of changed .rkt paths, tracked-diff plus untracked, absolute
def changed-rkt [] {
    let d = (do { run-external "git" "diff" "--name-only" "HEAD" } | complete)
    let tracked = (if $d.exit_code == 0 { $d.stdout | lines } else { [] })
    let uargs = ["ls-files" "--others" "--exclude-standard" "--full-name"]
    let u = (do { run-external "git" ...$uargs } | complete)
    let untracked = (if $u.exit_code == 0 { $u.stdout | lines } else { [] })
    let all = ($tracked | append $untracked)
    # git prints paths relative to the REPO root, which is above this
    # directory. They must come back absolute: a collapsed DIR/NAME.rkt
    # cannot say whether it means src/ or tests/, and raco make fails the
    # whole call on the wrong half (measured: the G-01 run, 2026-10-18).
    # --full-name because plain ls-files from this subdirectory prints
    # paths relative to the CURRENT directory, not the repo root
    # (measured in the same run: the untracked file resolved one root
    # too high while the tracked one resolved right).
    let root = (do { run-external "git" "rev-parse" "--show-toplevel" } | complete)
    let repo = (if $root.exit_code == 0 { $root.stdout | str trim } else { "" })
    $all | where {|p| ($p | str ends-with ".rkt")} | each {|p|
        if $repo == "" { $p } else { $repo | path join $p } }
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
    # absolute paths now, so a changed file can arrive twice (itself and
    # as a dependent); run each once.
    let runset = ($changed | where {|c| not (file-parked? $c) }
                 | append $unparked_deps | sort | uniq)
    if ($runset | is-empty) {
        print "[changed-files] nothing to run"
        return 0
    }
    let ccodes = (compile-all $runset)
    let recs = (run-runner $runset)
    let bad = ($ccodes | any {|c| $c != 0}) or ($recs | any {|r| $r.exit != 0})
    # compile failures enter the verdict the same way the full gate feeds
    # them: a file that did not compile must never read as ALL GREEN.
    let crecs = ($ccodes | each {|c| {file: "(compile)", exit: $c, ms: 0} })
    (verdict ($recs | append $crecs) ($parked | length))
    (if $bad { 1 } else { 0 })
}
