#!/usr/bin/env nu
# One job: the dispatcher — named stages, one table, --list.
# Registered in plan/package-tree.org. check.nu is the only gate entry point;
# no other script may be the thing someone runs "by hand" instead.
#
# Two rules this file keeps:
#   1. A stage with nothing to check prints NOTHING-TO-CHECK and never PASS.
#   2. The dispatcher prints how many stages checked nothing, so a green run
#      never hides a stage that did not look at anything.
# Stages need no edit here to start checking for real: each lint decides for
# itself whether it has something to check.
#
# No mutable variables: this phone's Nu has none, so results are collected as a
# list and counted from it. Every gate script follows that rule.

use ./env.nu *

const STAGES = [
    {name: "paren-check", script: "read-check.rkt", kind: "racket"}
    {name: "naming", script: "banned-words-lint.nu", kind: "nu"}
    {name: "one-way", script: "one-way-dependency-lint.nu", kind: "nu"}
    {name: "security-gate", script: "security-gate-lint.nu", kind: "nu"}
    {name: "language-split", script: "language-split-lint.nu", kind: "nu"}
]

# run-one stage returns what happened, and never raises: a stage that fails is
# a result to print, not an error that stops the dispatcher.
def run-one [stage] {
    if $stage.kind == "racket" {
        let files = (rkt_files)
        if ($files | is-empty) {
            {name: $stage.name, code: 0, out: "NOTHING-TO-CHECK paren-check: no Racket files exist yet"}
        } else {
            let r = (try { run-external (racket_bin) $"($gate_dir)/($stage.script)" ...$files | complete }
                     catch {|e| {stdout: $"(racket_bin) could not run: ($e)", exit_code: 3} })
            {name: $stage.name, code: $r.exit_code, out: ($r.stdout | str trim)}
        }
    } else {
        let r = (try { run-external nu $"($gate_dir)/($stage.script)" | complete }
                 catch {|e| {stdout: $"(nu) could not run ($stage.script): ($e)", exit_code: 3} })
        {name: $stage.name, code: $r.exit_code, out: ($r.stdout | str trim)}
    }
}

def main [ --list ] {
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

    let red = ($results | where {|r| $r.code != 0 } | length)
    let nothing = ($results | where {|r| $r.out =~ "NOTHING-TO-CHECK" } | length)

    print $"stages that checked nothing: ($nothing) of ($STAGES | length)"
    if $nothing > 0 {
        print "NOTHING-TO-CHECK above means the stage had nothing to check, not that the rule held"
    }
    let verdict = if $red == 0 { $"light gate: green, ($STAGES | length) stages ran" } else { $"light gate: red, ($red) of ($STAGES | length) stages" }
    print $verdict
    exit (if $red == 0 { 0 } else { 1 })
}