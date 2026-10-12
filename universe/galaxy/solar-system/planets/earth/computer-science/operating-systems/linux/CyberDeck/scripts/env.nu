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

# string? string -> string, a non-blank env value or ~/FALLBACK.
# Blank counts as unset, exactly like xdg-cache above; $nu.home-dir is
# the HOME the process actually runs under.
def or-home [raw, fallback: string] {
    if ($raw != null) and ((($raw | str trim) | is-not-empty)) {
        $raw | str trim
    } else {
        $nu.home-dir | path join $fallback
    }
}

# -> record, scope roots for the user scope (D-029): config, cache, data.
# The single Nu counterpart to core/scope.rkt: same variables, same
# blank-means-unset rule, same ~/. fallbacks. config = XDG_CONFIG_HOME
# or ~/.config; cache = XDG_CACHE_HOME or ~/.cache; data =
# XDG_DATA_HOME or ~/.local/share. xdg-cache above stays as it is: the
# gate's export-env path depends on its exact shape, so it is not
# refactored onto or-home. Exported (unlike xdg-cache) because check.nu
# and external callers reach it through `use scripts/env.nu`.
export def scope-roots [] {
    {
        config: (or-home ($env | get -o XDG_CONFIG_HOME?) ".config"),
        cache: (or-home ($env | get -o XDG_CACHE_HOME?) ".cache"),
        data: (or-home ($env | get -o XDG_DATA_HOME?) ".local/share"),
    }
}

export-env {
    # cargo is installed under ~/.cargo/bin, which is NOT on PATH in this
    # environment (command -v cargo fails on a bare shell). Appended here
    # for the E-25 cargo ecosystem (host cargo builds packages); nothing
    # is installed or fetched (D-020).
    let cargo_bin = ($nu.home-dir | path join ".cargo" "bin")
    if ($cargo_bin | path exists) {
        let have = ($env.PATH | split row ":")
        if not ($have | any {|p| $p == $cargo_bin }) {
            $env.PATH = ($have | append $cargo_bin | str join ":")
            print $"[env] PATH+=(($cargo_bin))"
        }
    }
}
