#!/usr/bin/env nu
# One job: the Nushell mirror of the one HOME seam — where HOME, the project
# tree and Racket live. Registered in plan/package-tree.org.
#
# No other gate script reads HOME or spells a path; everything starts here, so
# there is one place to change. machine/directories.rkt is the same seam for
# Racket, and the two must agree: HOME first, then the XDG defaults.
#
# Two facts about this phone's Nu (0.116 here) shape this file:
#   1. "path self" only runs at parse time, so every path below is a const.
#   2. A const name may not hold a hyphen, so the names use underscores.

# gate_dir is this directory; env.nu lives inside it.
export const gate_dir = path self | path dirname

# project_root is the AIU TERMINAL MULTIPLEXER directory: the gate sits one
# level below it, outside the package it checks.
export const project_root = $gate_dir | path dirname

# package_dir is where the code lives: the whole package, nothing outside it.
export const package_dir = $project_root | path join "multiplexer"

# package_src is where the areas are.
export const package_src = $package_dir | path join "src"

# package_index is the register: every path of the package, with its one job.
export const package_index = $package_dir | path join "INDEX.org"

# home_dir is the one HOME seam, mirrored for Nushell. $nu.home-path does not
# exist in this build and an environment value is not a parse-time constant
# here, so this is a def.
export def home_dir [] {
    $env.HOME
}

# racket_bin is Racket by full path. It is never taken from PATH: the phone's
# PATH names opt/racket/bin, which does not exist, and the install lives in
# opt/racket-full. Nothing here writes to any home config.
export def racket_bin [] {
    home_dir | path join "opt" | path join "racket-full" | path join "bin" | path join "racket"
}

# rkt_files lists every Racket file in the package, one path per entry.
export def rkt_files [] {
    glob $"($package_src)/**/*.rkt"
}

# package_paths lists every file and directory of the package, so the naming
# register can check that each one is named and that none is forgotten.
export def package_paths [] {
    glob $"($package_dir)/**/*"
}

# index_files lists the register and every area's own index, so an entry in any
# of them is checked, not only the ones in the register.
export def index_files [] {
    let under = (glob $"($package_dir)/**/INDEX.org")
    [$package_index] | append $under | uniq
}

# text_files lists every text file the gate lints: the package's text and the
# gate's own, because the gate is read by people too.
export def text_files [] {
    let a = (glob $"($package_dir)/**/*.org")
    let b = (glob $"($package_dir)/**/*.rkt")
    let c = (glob $"($package_dir)/**/*.nu")
    let d = (glob $"($gate_dir)/**/*.org")
    let e = (glob $"($gate_dir)/**/*.nu")
    $a | append $b | append $c | append $d | append $e
    | where {|f| ($f | path type) == "file" }
    | sort
}
