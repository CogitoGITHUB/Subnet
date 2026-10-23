#!/usr/bin/env nu
# enforcement-call-proof -- prove the gate goes RED when one enforcement
# call is deleted, and green again when the call is put back.
#
#   ~/opt/nushell/0.116.1/nu --no-config-file gate/enforcement-call-proof.nu
#
# Run from the project root. Why a script and not a claim: S-04's rule is
# that a rule nobody calls is a rule nobody enforces, and the stage that
# says so is only worth its lines if it BITES. So this deletes one real
# call, shows the red, puts the call back and shows the green, in a tree
# it leaves exactly as it found it.
#
# THE PROOF, in order:
#
#   0. it proves ONE call, named below, and not a class of calls: a
#      generalised version would have to guess at the shape of whatever
#      form it was deleting, and a proof that guesses is not a proof
#
#   1. the one file must be clean in git, so "unchanged" means unchanged
#   2. its bytes are hashed and copied into a scratch directory
#   3. ONE call is deleted: the (unless (source-pinned? c) form in
#      package-manager/src/spec/spec-fields.rkt that refuses a commit that
#      is not pinned. The form is four lines and only those four go, so
#      nothing else in the file changes
#   4. ONE stage runs: security-gate-lint. It must exit 1 and print
#      "predicate source-pinned? uncalled (S-04)", naming the rule the
#      deleted line was enforcing
#   5. the bytes are restored from the scratch copy
#   6. the same stage runs again and must exit 0
#   7. the sha256 and the git state of the file are compared with the
#      start: byte-identical, no pending change
#
# SAFETY. The restore is in a `finally`, so a failure in 3, 4 or 6 still
# puts the file back; step 7 fails loudly if it did not. A run killed
# outright (SIGKILL, no finally) is caught by step 1 on the next run, and
# `git checkout -- <file>` is the way back. The scratch copy is removed
# on the way out.
#
# Measured on the phone (Termux/proot): about four minutes per stage run,
# almost all of it the uncalled-predicates rule, which reads every .rkt
# file once per predicate. One stage, twice, and nothing else.

const TARGET = "package-manager/src/spec/spec-fields.rkt"
const CALL_LINE = "(unless (source-pinned? c)"
const CALL_END = "#:rule rule-source-trust))"
const STAGE = "security-gate-lint"
const RED_SAYS = "security-gate-lint: predicate source-pinned? uncalled (S-04)"

# path -> string, the sha256 of the file's bytes
def sha256-of [f: string] {
    open --raw $f | hash sha256
}

# path -> string, git's pending-change line for that path, "" when clean
def git-pending [f: string] {
    ^git status --porcelain -- $f | str trim
}

# nothing -> record, one gate stage run: exit code, both streams, seconds
def run-stage [] {
    let nu_bin = ($env | get -o CYBERDECK_NU? | default $nu.current-exe)
    let started = (date now | into int)
    let r = (with-env { CYBERDECK_STAGES: $STAGE } {
        do { run-external $nu_bin "--no-config-file" "gate/check.nu" }
    } | complete)
    {
        exit_code: $r.exit_code
        stdout: ($r.stdout | str trim)
        stderr: ($r.stderr | str trim)
        ms: (((date now | into int) - $started) / 1000000)
    }
}

# copy -> nothing, put the file back from the scratch copy, bytes and all
def restore [copy: string] {
    open --raw $copy | save --force --raw $TARGET
}

# nothing -> record {line, removed}, delete exactly one enforcement call
def delete-call [] {
    let ls = (open --raw $TARGET | lines)
    let hits = ($ls | enumerate
        | where {|r| ($r.item | str trim) == $CALL_LINE }
        | get index)
    if ($hits | length) != 1 {
        error make { msg: $"want exactly one line ($CALL_LINE) in ($TARGET), found ($hits | length)" }
    }
    let first = $hits.0
    let last = ($first + 3)
    if $last >= ($ls | length) {
        error make { msg: $"the call at ($TARGET):($first + 1) runs past the end of the file" }
    }
    # A shape we did not expect is a proof we must not fake.
    if not ((($ls | get $last | str trim) | str ends-with $CALL_END)) {
        error make { msg: $"the call at ($TARGET):($first + 1) does not end with ($CALL_END)" }
    }
    let kept = (($ls | take $first) | append ($ls | skip ($last + 1)))
    ((($kept | str join (char nl)) + (char nl)) | save --force --raw $TARGET)
    {line: ($first + 1), removed: 4}
}

# copy -> record {site, red, problem}, delete, run the stage, show it RED
def red-phase [copy: string] {
    try {
        let site = (delete-call)
        print $"proof: deleted ($site.removed) lines at ($TARGET):($site.line)"
        let red = (run-stage)
        print $"RED    stage ($STAGE) exit=($red.exit_code) in ($red.ms)ms"
        for l in ($red.stdout | lines) { print $"RED    ($l)" }
        print $"RED    the deleted call was at ($TARGET):($site.line)"
        {site: $site, red: $red, problem: ""}
    } catch {|e|
        {site: {line: 0, removed: 0}, red: {exit_code: -1, ms: 0}, problem: $e.msg}
    } finally {
        restore $copy
        print $"proof: restored ($TARGET) from ($copy)"
    }
}

# nothing -> nothing, the proof; exit 0 only when every step held
def main [] {
    if not ((($TARGET | path exists)) and (("gate/check.nu" | path exists))) {
        error make { msg: "enforcement-call-proof: run me from the project root" }
    }
    let pending = (git-pending $TARGET)
    if $pending != "" {
        error make { msg: $"($TARGET) has a pending change ($pending); run me on a clean file" }
    }
    let before = (sha256-of $TARGET)
    let scratch = (mktemp --directory)
    let copy = ($scratch | path join "spec-fields.rkt")
    (open --raw $TARGET | save --force --raw $copy)
    print $"proof: start ($TARGET) sha256=($before)"
    print $"proof: scratch copy ($copy)"
    let phase = (red-phase $copy)
    let green = (run-stage)
    let after = (sha256-of $TARGET)
    let diff_code = (do { ^git diff --quiet -- $TARGET } | complete | get exit_code)
    print $"GREEN  stage ($STAGE) exit=($green.exit_code) in ($green.ms)ms"
    for l in ($green.stdout | lines) { print $"GREEN  ($l)" }
    print $"proof: end ($TARGET) sha256=($after)"
    print $"proof: git status --porcelain ($TARGET) = '((git-pending $TARGET))'"
    print $"proof: git diff --quiet ($TARGET) exit=($diff_code)"
    let problems = ([
        (if $phase.problem != "" { $"red phase failed: ($phase.problem)" } else { "" })
        (if $phase.red.exit_code != 1 {
            $"red run exit ($phase.red.exit_code), wanted 1"
        } else { "" })
        (if not (($phase.red.stdout | str contains $RED_SAYS)) {
            $"red run did not say: ($RED_SAYS)"
        } else { "" })
        (if $green.exit_code != 0 { $"green run exit ($green.exit_code), wanted 0" } else { "" })
        (if not (($green.stdout | str contains ", 0 violations")) {
            "green run did not report 0 violations"
        } else { "" })
        (if $after != $before { $"($TARGET) sha256 changed: ($before) -> ($after)" } else { "" })
        (if $diff_code != 0 { $"git diff says ($TARGET) still differs" } else { "" })
        (if (git-pending $TARGET) != "" { $"git status says ($TARGET) is still pending" } else { "" })
    ] | where {|p| $p != "" })
    ^rm -rf $scratch
    if ($problems | is-empty) {
        print "proof: PASS -- gate is RED without the call, green with it, tree unchanged"
        exit 0
    }
    for p in $problems { print $"proof: FAIL ($p)" }
    exit 1
}
