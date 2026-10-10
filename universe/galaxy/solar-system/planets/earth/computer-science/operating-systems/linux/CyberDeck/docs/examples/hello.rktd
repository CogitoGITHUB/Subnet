(spec
  (format-version 2)
  (name hello)
  ;; The tree does not state its own version: configure.ac computes it with
  ;; build-aux/git-version-gen .tarball-version, which prints UNKNOWN outside
  ;; a release tarball (measured). NEWS' newest released version is 2.12.3
  ;; and this commit is development after it, so the .git suffix is the
  ;; honest reading of "2.12.3 plus whatever git has".
  (version "2.12.3.git")
  (summary "GNU Hello, the GNU canonical hello world program")
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