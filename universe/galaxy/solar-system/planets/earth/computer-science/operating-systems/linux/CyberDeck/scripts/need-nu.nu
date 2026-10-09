#!/usr/bin/env nu
# scripts/need-nu.nu -- report which Nushell project scripts would use.
#
# Converted from scripts/need-nu.sh. Manual version control only
# (D-020 amended): this script never downloads, installs or updates
# anything. It prefers the newest ~/opt/nushell/*/nu, else falls back
# to PATH, else fails clearly.
#
# The version gate runs first and is not advisory: Nu is pinned to
# 0.116.1 and this script refuses to run on anything else. It never
# fetches Nu to satisfy itself.
#
# Usage: eval "$(nu --no-config-file scripts/need-nu.nu)"

# Pinned Nushell (D-020). Change here and nowhere else.
const PINNED = "0.116.1"

# Exit codes: 0 ok, 2 no Nushell found (same as the old script),
# 3 the running Nu is not the pinned version.
const EXIT_NONE = 2
const EXIT_VERSION = 3

# -> string, current UTC instant, second precision
def utc [] {
    date now | format date "%Y-%m-%dT%H:%M:%SZ"
}

# -> string, version of the Nu running this script.
# $nu.current-exe, not bare "nu": bare nu resolves through PATH, which on
# this machine is a different version from the pinned one. 0.116.1 has no
# $nu.version column (verified), so the exe is asked directly.
def running-version [] {
    let exe = ($nu.current-exe)
    (do { run-external $exe "--version" } | complete).stdout | str trim
}

# Fails loudly when the running Nu is not the pinned one. Never fetches.
def require-pinned-version [] {
    let got = (running-version)
    if $got != $PINNED {
        print --stderr $"need-nu: nu ($got) is running, but ($PINNED) is pinned"
        print --stderr $"need-nu: refusing to run; install ($PINNED) by hand, scripts never fetch it"
        exit $EXIT_VERSION
    }
    $got
}

# -> string, newest ~/opt/nushell/*/nu, or "nu" from PATH, or error
def pick-nu [] {
    let base = ($nu.home-dir | path join "opt" "nushell")
    let dirs = (if ($base | path exists) { ls $base | get name | sort } else { [] })
    for dir in $dirs {
        let cand = ($dir | path join "nu")
        if ($cand | path exists) {
            return $cand
        }
    }
    let onpath = (^which nu | complete)
    if $onpath.exit_code == 0 {
        return "nu"
    }
    print --stderr "need-nu: no nushell found (~/opt/nushell/*/nu, then PATH)"
    print --stderr "need-nu: install one by hand; scripts never fetch it"
    exit $EXIT_NONE
}

def report-nu [] {
    print $"[need-nu] start utc=(utc)"
    # timeit cannot capture mutable variables (verified in 0.116.1), so
    # the timed block prints its own result line instead of returning one.
    let dur = (timeit {
        require-pinned-version | ignore
        let chosen = (pick-nu)
        let ver = (if $chosen == "nu" {
            running-version
        } else {
            # run-external takes the path as a value. Writing
            # run-external { $chosen } makes $chosen a closure PARAMETER
            # in Nu, which then fails to convert (verified in 0.116.1).
            (do { run-external $chosen "--version" } | complete).stdout | str trim
        })
        print $"nu: ($chosen) \(($ver)\)"
    })
    print $"[need-nu] end utc=(utc) after=(($dur | into int))ns"
}

report-nu
