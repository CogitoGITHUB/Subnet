#!/usr/bin/env nu
# One job: predicates called, writers audited — the security gate.
# Registered in plan/package-tree.org.
#
# Nothing can be audited yet: notation/src/security/ does not exist, so there
# are no predicates to look for and no writers to list. A stage with nothing
# to check prints NOTHING-TO-CHECK and never PASS.

use ./env.nu *

def main [] {
    let security = $package_src | path join "security"
    let present = ($security | path exists)

    if not $present {
        print "NOTHING-TO-CHECK security-gate: notation/src/security/ does not exist yet; no predicates to call and no writers to audit"
        exit 0
    }

    # The audit lands with the security area. Until then this stage says what
    # it would check, so the gap is named rather than hidden.
    print "NOTHING-TO-CHECK security-gate: the directory exists but the audit is not written yet"
    exit 0
}