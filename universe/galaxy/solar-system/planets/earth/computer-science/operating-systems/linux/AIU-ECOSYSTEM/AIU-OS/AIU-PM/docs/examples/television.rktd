(spec
  (format-version 2)
  (name television)
  (version "0.4.21")
  (summary "Fast, portable, hackable fuzzy finder for the terminal")
  (source (git "https://github.com/alexpasmantier/television.git"
               "ff25fb2ddeb9c6f70294e5099a617219e30248d8"))
  (build (steps (cargo #:dir "." #:args ("build" "--release"))))
  (install (prefix
    (bin "target/release/tv" "bin/tv")
    (check "tv" "--version")))
  (license mit)
  (homepage "https://github.com/alexpasmantier/television"))
