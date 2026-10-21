#!/usr/bin/env nu
# One job: the dispatcher — named stages, one table, --list.
# Registered in plan/package-tree.org. check.nu is the only gate entry point;
# no other script may be the thing someone runs "by hand" instead.
#
# Three rules this file keeps:
#   1. A stage with nothing to check prints NOTHING-TO-CHECK and never PASS.
#   2. The dispatcher prints how many stages checked nothing, so a green run
#      never hides a stage that did not look at anything.
#   3. text-lint and naming-register are checks of the file set itself — the
#      text of every file, and the register that names every path — so they live
#      here, in the file that owns that set. Every other stage is a script
#      beside this one.
#
# No mutable variables: this phone's Nu has none, so results are collected as a
# list and counted from it.

use ./env.nu *

# The stages the light gate runs, in order, with the script that runs each one
# and the kind of script it is. A name is what it checks, never its number.
const STAGES = [
    {name: "paren-check", script: "read-check.rkt", kind: "racket"}
    {name: "text-lint", script: "check.nu", kind: "text"}
    {name: "naming-register", script: "check.nu", kind: "register"}
    {name: "banned-words", script: "banned-words-lint.nu", kind: "nu"}
    {name: "one-way", script: "one-way-dependency-lint.nu", kind: "nu"}
    {name: "security-gate", script: "security-gate-lint.nu", kind: "nu"}
    {name: "language-split", script: "language-split-lint.nu", kind: "nu"}
]

# max_line is the line length the package and the gate keep to: 100 columns, so
# the tree reads on a phone without sideways scrolling.
const MAX_LINE = 100

# text_violations answers one string per text violation in one file, as
# "path:line: reason". Line 0 marks a whole-file property.
def text_violations [f] {
    let rel = ($f | path relative-to $project_root)
    let body = (open --raw $f)
    let ls = ($body | lines)
    let tabbed = ($ls | enumerate | where {|r| ($r.item | str contains (char tab)) } | each {|r|
        let n = ($r.index + 1)
        $"($rel):($n): tab"
    })
    let spaced = ($ls | enumerate | where {|r| ($r.item | str ends-with " ") } | each {|r|
        let n = ($r.index + 1)
        $"($rel):($n): trailing space"
    })
    let long = ($ls | enumerate | where {|r| ($r.item | str length) > $MAX_LINE } | each {|r|
        let n = ($r.index + 1)
        $"($rel):($n): line over ($MAX_LINE) characters"
    })
    let no_newline = (if ($body | str ends-with (char newline)) {
        []
    } else {
        [$"($rel):0: no final newline"]
    })
    $tabbed | append $spaced | append $long | append $no_newline
}

# run-text-lint answers the text stage: no tabs, no trailing space, no line over
# the limit, and a final newline in every text file.
def run-text-lint [] {
    let files = (text_files)
    let count = ($files | length)
    if ($count == 0) {
        {code: 0, out: "NOTHING-TO-CHECK text-lint: no text files exist yet"}
    } else {
        let bad = ($files | each {|f| text_violations $f } | flatten)
        let bad_count = ($bad | length)
        if ($bad_count == 0) {
            let what = $"($count) files, no tabs, no trailing space, no long line, final newline"
        {code: 0, out: $"OK text-lint: ($what)"}

        } else {
            let lines = ($bad | each {|v| $"TEXT ($v)" } | str join (char newline))
            {code: 1, out: $lines}
        }
    }
}

# index_entries answers every named entry of one INDEX.org: the name before the
# em dash, the job after it, and the directory the name is relative to. A prose
# bullet is not an entry: it has no em dash, or its name holds a space.
def index_entries [file] {
    let dir = ($file | path dirname)
    open --raw $file | lines | where {|l| (($l | str trim) | str starts-with "- ") } | each {|l|
        let body = (($l | str trim) | str substring 2..)
        let parts = ($body | split row " — ")
        let name = (($parts | first) | str trim)
        let words = ($name | split row " " | length)
        if (($parts | length) > 1) and ($words == 1) {
            let job = (($parts | skip 1 | str join " — ") | str trim)
            {name: $name, job: $job, dir: $dir, index: $file}
        } else {
            null
        }
    } | where {|e| $e != null }
}

# rel_path answers one path relative to the package, as a string with no
# trailing slash, so an entry in the register and a path on disk compare equal.
def rel_path [p] {
    let r = (($p | path relative-to $package_dir) | into string)
    $r | str replace --regex '/+$' ''
}

# run-naming-register answers the register stage: every path of the package is
# named in multiplexer/INDEX.org, every name states a job, and no entry names a
# path that is not there.
def run-naming-register [] {
    if (($package_index | path exists) == false) {
        return {code: 1, out: "REGISTER-MISSING multiplexer/INDEX.org does not exist"}
    }
    let indexes = (index_files)
    let paths = (package_paths)
    let have_count = ($paths | length)
    if ($have_count == 0) {
        let why = "NOTHING-TO-CHECK naming-register: the package has no paths, which is not a pass"
        return {code: 1, out: $why}
    }
    let have = ($paths | each {|p| rel_path $p } | where {|r| ($r | str length) > 0 })
    let top = (index_entries $package_index)
    let named = ($top | each {|e| rel_path ($e.dir | path join $e.name) })
    let missing = ($have | where {|p| (($named | where {|n| $n == $p }) | is-empty) })
    let all = ($indexes | each {|f| index_entries $f } | flatten)
    let jobless = ($all | where {|e| (($e.job | str length) == 0) })
    let stale = ($all | where {|e|
        let r = (rel_path ($e.dir | path join $e.name))
        (($have | where {|p| $p == $r }) | is-empty)
    })
    let bad_count = ($missing | length) + ($jobless | length) + ($stale | length)
    if ($bad_count == 0) {
        let named_count = ($named | length)
        let what = $"($have_count) paths, every one named in multiplexer/INDEX.org with its job"
        {code: 0, out: $"OK naming-register: ($what); ($named_count) entries checked, none stale"}
    } else {
        let a = ($missing | each {|p| $"REGISTER-MISSING ($p): no entry in multiplexer/INDEX.org" })
        let b = ($jobless | each {|e| $"REGISTER-NAME-BAD ($e.name): the name states no job" })
        let c = ($stale | each {|e| $"REGISTER-STALE ($e.name): no such path in the package" })
        let lines = ($a | append $b | append $c | str join (char newline))
        {code: 1, out: $lines}
    }
}

# run-one answers what happened in one stage, and never raises: a stage that
# fails is a result to print, not an error that stops the dispatcher.
def run-one [stage] {
    if $stage.kind == "racket" {
        let files = (rkt_files)
        if ($files | is-empty) {
            let why = "NOTHING-TO-CHECK paren-check: no Racket files exist yet"
            {name: $stage.name, code: 0, out: $why}
        } else {
            let script = $"($gate_dir)/($stage.script)"
            let r = (try { run-external (racket_bin) $script ...$files | complete }
                     catch {|e| {stdout: $"(racket_bin) could not run: ($e)", exit_code: 3} })
            {name: $stage.name, code: $r.exit_code, out: ($r.stdout | str trim)}
        }
    } else if $stage.kind == "text" {
        let r = (run-text-lint)
        {name: $stage.name, code: $r.code, out: $r.out}
    } else if $stage.kind == "register" {
        let r = (run-naming-register)
        {name: $stage.name, code: $r.code, out: $r.out}
    } else {
        let r = (try { run-external nu $"($gate_dir)/($stage.script)" | complete }
                 catch {|e| {stdout: $"nu could not run ($stage.script): ($e)", exit_code: 3} })
        {name: $stage.name, code: $r.exit_code, out: ($r.stdout | str trim)}
    }
}

# main runs every stage and prints each one's output plus the verdict; with
# --list it only names the stages and the scripts they run.
def main [--list] {
    if $list {
        print $"the light gate has ($STAGES | length) stages:"
        for s in $STAGES {
            print $"  ($s.name)  ->  ($s.script)  [($s.kind)]"
        }
        exit 0
    }

    let results = ($STAGES | each {|s| run-one $s })

    for r in $results {
        print $"--- ($r.name)"
        print $r.out
    }

    let total = ($STAGES | length)
    let red = ($results | where {|r| $r.code != 0 } | length)
    let nothing = ($results | where {|r| $r.out =~ "NOTHING-TO-CHECK" } | length)

    print $"stages that checked nothing: ($nothing) of ($total)"
    if $nothing > 0 {
        print "NOTHING-TO-CHECK above means the stage had nothing to check, not that the rule held"
    }
    let verdict = if $red == 0 {
        $"light gate: green, ($total) stages ran"
    } else {
        $"light gate: red, ($red) of ($total) stages"
    }
    print $verdict
    exit (if $red == 0 { 0 } else { 1 })
}
