#!/usr/bin/env nu
# One job: the security gate — every security rule is called on a value that
# must be refused and on a value that must pass, and the answer is checked.
# Registered in plan/package-tree.org; gate stage "security-gate".
#
# The stage calls gate/security-probe.rkt, which opens the security area and
# probes every rule, and the probe also names the files that call each rule,
# so a rule nobody calls is named and not hidden. A stage with nothing to
# check prints NOTHING-TO-CHECK and never PASS.
#
# The probe is called with a path relative to the project directory, because
# the project directory holds a space and racket splits an argument that holds
# one when it opens a module file.

use ./env.nu *

# main runs the probe and prints what it said. It exits non-zero when the
# probe did not pass, so the gate stops the run instead of waving a broken
# rule through.
def main [] {
    let security = $package_src | path join "security"
    if not ($security | path exists) {
        print "NOTHING-TO-CHECK security-gate: notation/src/security/ does not exist; no rules to call"
        exit 0
    }

    let probe = $gate_dir | path join "security-probe.rkt"
    if not ($probe | path exists) {
        print "FAIL security-gate: gate/security-probe.rkt is missing; the stage has nothing to run"
        exit 1
    }

    cd $project_root
    let rkt = (racket_bin)
    let security_file = $security | path join "security.rkt"
    let res = (run-external $rkt "gate/security-probe.rkt" $security_file $package_src $security | complete)

    if $res.exit_code != 0 {
        print "FAIL security-gate: the probe did not pass"
        for line in ($res.stdout | lines) {
            print $line
        }
        for line in ($res.stderr | lines) {
            print $line
        }
        exit 1
    }

    for line in ($res.stdout | lines) {
        print $line
    }
    print "OK security-gate — every security rule answered as it says"
    exit 0
}
