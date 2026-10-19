# One job: the Nushell mirror of the one HOME seam — where HOME, the project tree and Racket live.
# Registered in plan/package-tree.org. No other gate script reads HOME or
# spells a path; everything starts here, so there is one place to change.
#
# Two facts about this phone's Nu (0.116 here) shape this file:
#   1. "path self" only runs at parse time, so every path below is a const.
#   2. A const name may not hold a hyphen, so the names use underscores.

# gate_dir is this directory; env.nu lives inside it.
export const gate_dir = path self | path dirname

# project_root is the AIU EDITOR directory: the gate sits one level below it.
export const project_root = $gate_dir | path dirname

# package_dir is where the code lives; gate stages look only here and in gate_dir.
export const package_dir = $project_root | path join "editor"

# package_src is where the areas are.
export const package_src = $package_dir | path join "src"

# tools_dir is where the dev scripts live: the probes and the build helpers.
# They are not part of the package, but the gate still reads them, so they
# carry a header and a comment above every definition like the rest.
export const tools_dir = $project_root | path join "tools"

# home_dir is the one HOME seam, mirrored for Nushell (machine/directories.rkt
# is the same seam for Racket). $nu.home-path does not exist in this build and
# an environment value is not a parse-time constant here, so this is a def.
export def home_dir [] {
    $env.HOME
}

# racket_bin is Racket by full path. It is never taken from PATH: the phone's
# PATH names opt/racket/bin, which does not exist, and the install lives in
# opt/racket-full. Nothing here writes to any home config.
export def racket_bin [] {
    home_dir | path join "opt" | path join "racket-full" | path join "bin" | path join "racket"
}

# rkt_files lists every Racket file in the package, one path per line.
export def rkt_files [] {
    glob $"($package_src)/**/*.rkt" | lines
}
