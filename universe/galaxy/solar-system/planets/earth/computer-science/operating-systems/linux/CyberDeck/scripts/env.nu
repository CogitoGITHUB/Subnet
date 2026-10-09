#!/usr/bin/env nu
# scripts/env.nu -- shared environment for CyberDeck project scripts.
#
# Before running racket by hand, source this file:
#   use scripts/env.nu
#
# Racket's compiled/ output is deliberately NOT redirected (D-027).
# Measured on this phone, PLTCOMPILEDROOTS="<cache>:same" made raco make
# 401s and raco test 216s on a 2-module project versus 18s unset, and the
# cache kept growing because the first root is the write root and Racket
# re-emits its own stock libraries there. compiled/ stays in-tree and is
# gitignored. Do not add PLTCOMPILEDROOTS here.

# -> string, the XDG cache dir: $XDG_CACHE_HOME when set, else ~/.cache
def xdg-cache [] {
    let from_env = ($env | get -o XDG_CACHE_HOME?)
    if ($from_env != null) and (($from_env | str trim) | is-not-empty) {
        $from_env | str trim
    } else {
        $nu.home-dir | path join ".cache"
    }
}

# Cargo output goes to the XDG cache for NEW builds only. No existing
# in-tree target/ directory is removed by this (D-027).
export-env {
    let dir = ((xdg-cache) | path join "cyberdeck" "target")
    mkdir ($dir | into string)
    $env.CARGO_TARGET_DIR = $dir
    print $"[env] CARGO_TARGET_DIR=($dir)"
    # cargo is installed under ~/.cargo/bin, which is NOT on PATH in this
    # environment (command -v cargo fails on a bare shell). Appended here
    # for project scripts only; nothing is installed or fetched (D-020).
    let cargo_bin = ($nu.home-dir | path join ".cargo" "bin")
    if ($cargo_bin | path exists) {
        let have = ($env.PATH | split row ":")
        if not ($have | any {|p| $p == $cargo_bin }) {
            $env.PATH = ($have | append $cargo_bin | str join ":")
            print $"[env] PATH+=(($cargo_bin))"
        }
    }
}
