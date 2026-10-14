(spec
  (format-version 2)
  (name bats-core)
  (version "1.14.0")
  (summary "Bash automated testing system")
  (source (git "https://github.com/bats-core/bats-core.git"
               "eb7f42f8d608ac693d7a4b67474f6714ea68cfc5"))
  (build (steps
    (run #:argv ("./install.sh" "$PREFIX") #:dir ".")))
  (install (prefix
    (bin "bin/bats")
    (libexec "libexec/bats-core/bats")
    (share "lib/bats-core")
    (man "share/man/man1/bats.1")
    (man "share/man/man7/bats.7")
    (check "bin/bats" "--version")))
  (license mit)
  (homepage "https://github.com/bats-core/bats-core"))
