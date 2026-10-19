#!/usr/bin/env nu
# One job: the load check — verify every .rkt module under notation/ and gate/ loads cleanly in Racket.
# Registered in plan/package-tree.org; gate stage "load-check".
#
# Runs: racket -l racket/base -e '(dynamic-require (string->path "<abs path>") (void))'
# for every .rkt module under notation/ and gate/ by the full Racket path,
# capturing the first error line on failure.

use ./env.nu *

# check-one loads one module by its full path and answers whether it loaded,
# carrying the first error line when it did not.
def check-one [abs_path: string, rel_path: string] {
    let rkt = (racket_bin)
    let code = $"\(dynamic-require \(string->path \"($abs_path)\"\) \(void\)\)"
    let res = (run-external $rkt "-l" "racket/base" "-e" $code | complete)
    if $res.exit_code == 0 {
        {file: $rel_path, ok: true, status: "LOADS"}
    } else {
        let err_text = if ($res.stderr | is-empty) { $res.stdout } else { $res.stderr }
        let first_err = ($err_text | lines | where {|l| not ($l | is-empty) } | first | default "load failed")
        {file: $rel_path, ok: false, status: $first_err}
    }
}

# main loads every .rkt module under notation/ and gate/ and prints the result;
# with --table it prints one line per module, and it exits non-zero if any failed.
def main [ --table ] {
    let gate_files = (glob $"($gate_dir)/**/*.rkt")
    let pkg_files = (glob $"($package_dir)/**/*.rkt")
    let all_files = ($gate_files | append $pkg_files | sort)
    let total = ($all_files | length)

    if $total == 0 {
        print "NOTHING-TO-CHECK load-check: no Racket files exist"
        exit 0
    }

    let results = ($all_files | each {|f|
        let rel = ($f | path relative-to $project_root)
        check-one $f $rel
    })

    let failed = ($results | where {|r| not $r.ok })
    let fail_count = ($failed | length)
    let pass_count = ($total - $fail_count)

    if $table {
        for r in $results {
            print $"($r.file): ($r.status)"
        }
        print $"load-check: ($pass_count) passed, ($fail_count) failed of ($total) modules"
    } else {
        if $fail_count == 0 {
            print $"OK load-check — ($total) modules loaded cleanly"
        } else {
            for r in $failed {
                print $"FAIL ($r.file): ($r.status)"
            }
            print $"load-check: ($pass_count) passed, ($fail_count) failed of ($total) modules"
        }
    }

    if $fail_count == 0 {
        exit 0
    } else {
        exit 1
    }
}
