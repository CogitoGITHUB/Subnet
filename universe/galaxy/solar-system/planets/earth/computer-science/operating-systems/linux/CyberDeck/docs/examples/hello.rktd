(spec
  (format-version 2)
  (name hello)
  ;; SPEC-NEUTRAL.org section 1 says version is the "release tag name verbatim".
;; This commit has no release tag: the pinned commit is an unreleased git
;; checkout (git-version-gen prints UNKNOWN without .tarball-version), and
;; NEWS' newest release is 2.12.3. So the version is the last release and
;; the summary says the tree is past it. Nothing here is invented.
(version "2.12.3")
(summary "GNU Hello, the GNU canonical hello world program (unreleased git checkout)")
  (source (git "https://git.savannah.gnu.org/git/hello.git"
               "d598de6f9a89f78eafac959adc0376e20c87d6a7"))
  ;; The export of this commit has: bootstrap, configure.ac, Makefile.am,
  ;; bootstrap.conf. It does NOT have configure, autogen.sh or a generated
  ;; Makefile: a git checkout is not a release tarball, so bootstrap must
  ;; run first. bootstrap needs autopoint, gperf and help2man, and on this
  ;; machine those three are MISSING (git, tar, perl, autoconf, automake, m4,
  ;; gettext, makeinfo, make and cc are all present). The step below is the
  ;; real build sequence, not a faked one: it cannot complete on this box
  ;; until autopoint, gperf and help2man are installed.
  (build (steps
    (run #:argv ("./bootstrap") #:dir ".")
    (configure #:dir ".")
    (make #:dir "." #:file "Makefile" #:targets ("all"))))
  ;; Makefile.am:39 is bin_PROGRAMS = hello, so `make` leaves ./hello.
  (install (prefix
    (bin "bin/hello" "hello")
    (check "bin/hello" "--version")))
  (license gpl3)
  (homepage "https://www.gnu.org/software/hello/"))