#!/usr/bin/env nu
# one-way-dependency-lint -- ARCHITECTURE.org's area law, made enforceable.
#
# Every directory under package-manager/src is an AREA. An area may depend
# on the areas BELOW it and never on one above, and ARCHITECTURE.org names
# two directions that must never appear at all: errors/ is the floor (it
# requires nothing) and entry/ is the ceiling (nothing requires it).
#
# A law written only in prose drifts the first time someone is in a hurry,
# so the table below is that law, transcribed, and this stage is the gate.
#
# Cross-area requires are written "../AREA/file.rkt" (same-area ones are
# "./file.rkt"), so each line names its own target and no resolver is
# needed to check it.

# The area on the left may require only the areas on the right. install and
# entry are not listed: they may use anything below them, which the two
# absolute rules already bound.
const MAY_USE = {
    errors: []
    narration: [errors]
    machine: [errors narration]
    security: [errors]
    spec: [errors security]
    process: [errors narration machine]
    git: [errors narration process machine]
    build: [process errors narration spec]
    store: [spec git errors narration]
    queue: [errors narration machine store]
    backup: [git spec errors narration]
}

const ANY_BELOW = [install entry]

# The law above is what ARCHITECTURE.org SAYS. This is what the tree DOES,
# measured on 2026-10-17: 34 edges cross it, in 14 area-pairs. That is a
# real finding, not a lint bug -- spec/ and git/ require each other, and
# ten modules reach up into entry/. Fixing them means moving modules and
# breaking a cycle, which is a decision, recorded in plan/OPEN-DECISIONS.org.
#
# They are listed here so the debt is VISIBLE ON EVERY RUN and so that a
# NEW crossing still fails the gate. Deleting a pair from this list is the
# fix; adding one is how the debt grows, and it should hurt.
const KNOWN_PAIRS = [
    [git security] [git spec] [git store]
    [machine git] [machine spec] [narration machine]
    [queue git] [queue spec] [security git]
    [spec git] [store install] [store machine] [store queue]
]
# The ceiling rule is crossed by exactly these ten modules, measured
# 2026-10-17. Named file by file rather than waved through, so an
# ELEVENTH module reaching into entry/ still fails the gate: a blanket
# "the ceiling is known debt" would have been a loophole, not a ledger.
const KNOWN_CEILING = [
    "install/apply.rkt"
    "machine/file-lock.rkt"
    "spec/plan-actions.rkt"
    "spec/plan-derive.rkt"
    "spec/plan-hash.rkt"
    "spec/plan-lower.rkt"
    "spec/resolve.rkt"
    "spec/spec-fields.rkt"
    "spec/spec.rkt"
    "store/query.rkt"
]

# string string string -> bool, is this crossing already counted as debt.
# rel is the path relative to package-manager/src/, which is the form the
# ceiling list is written in.
def known-crossing [from: string, to: string, rel: string] {
    if $to == 'entry' {
        return ($KNOWN_CEILING | any {|r| $r == $rel })
    }
    ($KNOWN_PAIRS | any {|p| ($p | get 0) == $from and ($p | get 1) == $to })
}

# string string -> string, the reason this edge is illegal, or "" if it is
# fine. Returning the REASON rather than a boolean is deliberate: the
# message is what a reader acts on, and "violation" alone would send them
# back to the doc to find out which rule they broke.
def violation-of [from: string, to: string] {
    if $to == 'entry' {
        return 'entry is the ceiling: nothing may require it'
    }
    if $from == 'errors' {
        return 'errors is the floor: it may require nothing'
    }
    if ($ANY_BELOW | any {|a| $a == $from }) {
        return ''
    }
    let allowed = ($MAY_USE | get -o $from)
    if $allowed == null {
        return $"unknown area ($from): add it to the table in this lint"
    }
    if ($allowed | any {|a| $a == $to }) {
        return ''
    }
    return $"($from) may not require ($to)"
}

def main [] {
    let files = (git ls-files package-manager/src | lines
                 | where {|f| $f | str ends-with '.rkt' })
    mut out = []
    mut known = 0
    for f in $files {
        let area = ($f | path split | get 2)
        let rel = ($f | str replace 'package-manager/src/' '')
        let ls = (open --raw $f | lines)
        # A (module+ test) block may reach anywhere it needs to assert on:
        # the one-printer-lint set that precedent, and an inline test
        # requiring ../entry is a test doing its job, not an area
        # depending upwards. The line index of that form is found once
        # and used as the cut.
        let starts = ($ls | enumerate | where {|r|
            ($r.item | str trim) == '(module+ test'
        } | get index)
        let test_at = (if ($starts | is-empty) { $ls | length } else { $starts | first })
        for l in ($ls | enumerate) {
            if $l.index >= $test_at { continue }
            let hits = ($l.item | parse -r '\.\./(?<area>[a-z0-9-]+)/')
            if ($hits | is-empty) { continue }
            for t in ($hits | get area | uniq) {
                if $t == $area { continue }
                let why = (violation-of $area $t)
                if $why == '' { continue }
                if (known-crossing $area $t $rel) {
                    $known = ($known + 1)
                    continue
                }
                let n = ($l.index + 1)
                $out = ($out | append $"one-way-dependency-lint: ($why) ($f):($n)")
            }
        }
    }
    let summary = ($"one-way-dependency-lint: ($files | length) files, "
                 + $"($known) known unpaid edges, ($out | length) new violations")
    print $summary
    for v in $out { print $v }
    if ($out | length) > 0 { exit 1 }
}
