#!/usr/bin/env nu
# scripts/startup.nu -- measure Racket startup N times, print the median.
#
# Converted from scripts/startup.sh. Measurement only; changes nothing
# about startup. N defaults to 5.
#
# D-026: this is WALL TIME ONLY. The old script scraped user/sys CPU
# from the children line of `times`. Nu 0.116.1 has no equivalent
# (timeit measures wall duration, there is no bench command), and this
# Racket build has no current-process-*-milliseconds either, so there is
# no pure-Nu source for user/sys on this machine. Shelling out to
# `times` was rejected: it reintroduces sh. Baselines recorded before
# 2026-10-09 are therefore NOT comparable -- see docs/PERF.org.
#
# N comes from $env.CYBERDECK_STARTUP_N, not a positional argument:
# this Nu build exposes no args column on $nu or $env, so a positional
# argument cannot be read back (verified in 0.116.1).

# Pinned Nushell (D-020). Change here and nowhere else.
const PINNED = "0.116.1"

# Exit codes: 0 ok, 2 racket not found, 3 the running Nu is not pinned.
const EXIT_NO_RACKET = 2
const EXIT_VERSION = 3

# -> string, current UTC instant, second precision
def utc [] {
    date now | format date "%Y-%m-%dT%H:%M:%SZ"
}

# -> float, seconds with two decimals, the old table's %.2f
def secs [ns] {
    ($ns | into float) / 1000000000.0 | math round --precision 2
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
        print --stderr $"startup: nu ($got) is running, but ($PINNED) is pinned"
        print --stderr $"startup: refusing to run; install ($PINNED) by hand, scripts never fetch it"
        exit $EXIT_VERSION
    }
}

# -> string, the Racket this script measures
def racket-exe [] {
    let exe = ($nu.home-dir | path join "opt" "racket" "bin" "racket")
    if not ($exe | path exists) {
        print --stderr $"startup: racket not found at ($exe)"
        exit $EXIT_NO_RACKET
    }
    $exe
}

# -> int, how many runs to measure
def run-count [] {
    let raw = ($env | get -o CYBERDECK_STARTUP_N?)
    if $raw == null { 5 } else { $raw | into int }
}

# string -> nothing, one measured startup, output discarded
def measure-once [exe] {
    do { run-external $exe "-l" "racket/base" "-e" "(void)" } | complete | ignore
}

# -> float, the median wall time in seconds.
# Old script took sorted line N/2+1, i.e. 0-based index N/2. slice is used
# rather than get: get takes a cell path, not a computed index.
def median-of [values] {
    let sorted = ($values | sort-by { $in })
    # length/2 is a float; slice needs an int range
    let idx = (($sorted | length) / 2 | math floor | into int)
    let ns = ($sorted | slice 0..<$idx | last)
    secs $ns
}

# string int -> list, one monotonic wall measurement per run.
# Defined outside report-startup: a closure nested directly inside a
# timeit block fails in 0.116.1 ("Eval block failed with pipeline input").
def run-times [exe n] {
    1..$n | each {|i|
        let ns = (timeit { measure-once $exe } | into int)
        print $"[startup] run ($i) real=((secs $ns))s"
        $ns
    }
}

def print-table [times] {
    print "| run | real |"
    for t in ($times | enumerate) {
        let idx = ($t.index + 1)
        let s = (secs $t.item)
        # joined, not escaped: ")" cannot be escaped inside $"..."
        print ([$"| " $"($idx)" $" | ($s) |"] | str join "")
    }
    let med = (median-of $times)
    print ([$"| median | ($med) |"] | str join "")
}

def report-startup [] {
    require-pinned-version
    let n = (run-count)
    let exe = (racket-exe)

    # warm the image cache first, exactly as the old script did, so run 1
    # is not measuring a cold start
    measure-once $exe

    print $"[startup] start utc=(utc) n=($n) mode=wall-only"
    # timeit cannot capture mutable variables (verified in 0.116.1) and
    # discards the closure's value, so the timed block prints its own
    # table; the end line uses the duration timeit returns.
    let total = (timeit { print-table (run-times $exe $n) })
    print $"[startup] end utc=(utc) after=(($total | into int))ns"
}

report-startup