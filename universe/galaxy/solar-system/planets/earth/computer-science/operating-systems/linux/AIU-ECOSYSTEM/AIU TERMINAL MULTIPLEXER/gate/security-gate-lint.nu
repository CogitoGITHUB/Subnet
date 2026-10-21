#!/usr/bin/env nu
# One job: the security gate — the predicates are called, the writers are audited.
# Registered in plan/package-tree.org.
#
# The multiplexer's security area does not exist yet, so this stage has nothing
# to check: it prints NOTHING-TO-CHECK and never PASS. A stage that checked
# nothing must not look like a rule that held.
#
# When the area lands, this stage finds the predicates the area defines and
# names, for each one, the files that call it. A predicate nobody calls is a
# rule that protects nothing, so the stage says so and fails.

use ./env.nu *

# security_dir is the area that holds the rules, when it exists.
def security_dir [] {
    $package_src | path join "security"
}

# predicate_names returns the names the rule files define, read from the
# (define (name ...)) lines of every rule file.
def predicate_names [files] {
    $files | each {|p|
        let head = "(define ("
        open --raw $p | lines | where {|l| ($l | str trim) | str starts-with $head } | each {|l|
            let inside = $l | str replace --regex '^\(define \(' ''
            let name = $inside | str trim | split row " " | first
            {name: $name, file: $p}
        }
    } | flatten
}

# callers_of returns the files outside the security area that call a name.
def callers_of [name files] {
    $files | where {|p| (open --raw $p | str contains "(name ") }
}

# main reports, for every predicate of the security area, who calls it.
def main [] {
    let dir = security_dir

    if (($dir | path exists) == false) {
        print "NOTHING-TO-CHECK security-gate — the security area does not exist yet"
        exit 0
    }

    let rule_files = ((glob $"($dir)/**/*.rkt") | lines)
    if ($rule_files | is-empty) {
        print "NOTHING-TO-CHECK security-gate — the security area holds no rule file yet"
        exit 0
    }

    let all_racket = ((glob $"($package_src)/**/*.rkt") | lines)
    let predicates = predicate_names $rule_files

    if ($predicates | is-empty) {
        print "NOTHING-TO-CHECK security-gate — the security area defines no predicate yet"
        exit 0
    }

    let uncalled = ($predicates | where {|p|
        let outside = ($all_racket | where {|f| ($f | path dirname) != $dir })
        (callers_of $p.name $outside | is-empty)
    })

    for p in $predicates {
        let outside = ($all_racket | where {|f| ($f | path dirname) != $dir })
        let who = (callers_of $p.name $outside | each {|f| $f | path relative-to $project_root })
        if ($who | is-empty) {
            print $"CALLER ($p.name) — no file calls it yet"
        } else {
            print $"CALLER ($p.name) — called by ($who | str join ', ')"
        }
    }

    let bad = ($uncalled | length)
    if $bad == 0 {
        print $"OK security-gate — ($predicates | length) predicates, every one is called"
        exit 0
    }
    print $"SECURITY-GATE — ($bad) of ($predicates | length) predicates have no caller"
    exit 1
}
