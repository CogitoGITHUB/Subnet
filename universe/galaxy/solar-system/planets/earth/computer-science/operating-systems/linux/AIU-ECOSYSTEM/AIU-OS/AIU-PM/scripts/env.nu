#!/usr/bin/env nu
# scripts/env.nu -- shared environment for CyberDeck project scripts.
#
# Before running racket by hand, source this file:
#   use scripts/env.nu
#
# Racket's compiled/ output lives OUTSIDE the tree, under one root, so no
# compiled/ directory is ever created beside a source file (D-027 was
# reversed deliberately; the reasoning is below and in
# plan/OPEN-DECISIONS.org).
#
# D-027 measured PLTCOMPILEDROOTS="<cache>:same" -- TWO roots, the second
# being the literal value "same" -- and found raco make 401s and raco test
# 216s on a 2-module project against 18s unset, with the cache growing
# because Racket re-emitted its own stock libraries into the write root.
#
# That result does not transfer to ONE root, and the difference was
# measured rather than argued: with PLTCOMPILEDROOTS set to a single root
# and no ":same", loading racket/list and racket/string left the root at
# its previous file count and mirrored no collects/ or pkgs/ path into it.
# The stock-library re-emission does not happen, so the 401s does not
# follow from this configuration. A cold root costs one rebuild, which is
# the same thing a fresh checkout costs anyway.
#
# The old note is kept here on purpose: a reader who remembers D-027 needs
# to know it was reversed and why, not to find it silently gone.

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
    # Racket's compiled output goes to ONE root outside the source tree, so
    # the tree never grows a compiled/ directory. Set here and nowhere else
    # on purpose: two roots, or a per-command override, means two caches,
    # and two caches means stale bytecode can outlive the source it came
    # from. Every racket and raco the gate spawns through `^` inherits this.
    # scripts/test-runner.rkt and read-check.rkt spawn nothing, so they
    # inherit it without being edited.
    let compiled_root = ($nu.home-dir | path join ".local" "share" "aiu-pm" "compiled")
    if not ($compiled_root | path exists) {
        mkdir $compiled_root
    }
    if (($env | get -o PLTCOMPILEDROOTS?) != $compiled_root) {
        $env.PLTCOMPILEDROOTS = $compiled_root
        print $"[env] PLTCOMPILEDROOTS=($compiled_root)"
    }
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
