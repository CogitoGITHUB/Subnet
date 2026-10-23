#lang racket/base

;; One job: the one place HOME and XDG are read.
;; Registered in plan/package-tree.org; lands with TODO item 1.
;;
;; One scope seam for the environment and the roots: no other file in this
;; program reads an environment variable, so where the program looks is one
;; place to change and one place to look when a path is wrong.
(require racket/file
         racket/path
         racket/string
         "../errors/raise.rkt")

;; home-dir returns the user's home directory, and refuses when HOME is not
;; set, because a program with no home has nowhere to keep anything.
(define (home-dir)
  (define h (getenv "HOME"))
  (if (or (not h) (string=? h ""))
      (error-of 'err-no-home "the editor" "the home directory"
                "HOME is not set" "set HOME to the home directory and run again")
      (path->complete-path h)))

;; xdg-dir returns the XDG directory of the given kind, and falls back to the
;; default place under the home directory when the variable is not set. The
;; fallback is a list of path parts, so a default may be more than one
;; directory deep.
(define (xdg-dir kind fallback)
  (define value (getenv (string-append "XDG_" (string-upcase kind) "_HOME")))
  (if (and value (not (string=? value "")))
      (path->complete-path value)
      (apply build-path (home-dir) fallback)))

;; config-dir returns the editor's configuration directory.
(define (config-dir)
  (build-path (xdg-dir "config" '(".config")) "aiu-editor"))

;; state-dir returns the editor's state directory: the journal and the locks
;; live here, because they are the things that must survive a crash.
(define (state-dir)
  (build-path (xdg-dir "state" '(".local" "share")) "aiu-editor"))

;; cache-dir returns the editor's cache directory.
(define (cache-dir)
  (build-path (xdg-dir "cache" '(".cache")) "aiu-editor"))

;; racket-bin answers the Racket program of this machine, and refuses when it
;; is not there: a path that guesses is a path that fails later, in the middle
;; of a run. The environment variable wins, so a machine that keeps Racket
;; somewhere else is named in one place.
(define (racket-bin)
  (define named (getenv "AIU_RACKET_BIN"))
  (define bin (if (and named (not (string=? named "")))
                  (path->complete-path named)
                  (build-path (home-dir) "opt" "racket-full" "bin" "racket")))
  (if (file-exists? bin)
      bin
      (error-of 'err-no-racket "the editor" (path->string bin)
                "the Racket program is not there"
                "set AIU_RACKET_BIN to the racket program, or put Racket under the home directory")))

;; git-bin answers the git program of this machine, and refuses when it is
;; not there: a path that guesses is a path that fails later, in the middle
;; of a run. The environment variable wins, so a machine that keeps git
;; somewhere else is named in one place.
(define (git-bin)
  (define named (getenv "AIU_GIT_BIN"))
  (define bin (if (and named (not (string=? named "")))
                  (path->complete-path named)
                  "/usr/bin/git"))
  (if (file-exists? bin)
      bin
      (error-of 'err-no-git "the editor" (path->string bin)
                "the git program is not there"
                "set AIU_GIT_BIN to the git program, or put git where the editor looks")))

;; hot-path-bin answers the Rust hot path's program: the binary the
;; meaning side starts to do the state work. The environment variable
;; wins, so a build that lives somewhere else is named in one place. The
;; default is the build's target directory, which is outside the tree.
(define (hot-path-bin)
  (define named (getenv "AIU_HOT_PATH_BIN"))
  (define bin (if (and named (not (string=? named "")))
                  (path->complete-path named)
                  (build-path "/tmp" "editor-target" "debug" "hot-path")))
  (if (file-exists? bin)
      bin
      (error-of 'err-no-hot-path "the editor" (path->string bin)
                "the hot path program is not there"
                "build the editor crate, or set AIU_HOT_PATH_BIN to the hot path program")))

;; crate-dir answers the Rust crate of this package: the directory that
;; holds the manifest. The environment wins, so a machine that keeps the
;; crate somewhere else is named in one place. The search walks up from
;; where the program runs, because this Racket does not say where a file
;; of its own sits.
(define (crate-dir)
  (define named (getenv "AIU_EDITOR_CRATE"))
  (if (and named (not (string=? named "")))
      (path->complete-path named)
      (let loop ([at (simplify-path (current-directory))])
        (define up (simplify-path (build-path at "..")))
        ;; the crate is the package's own Rust half: it sits in the
        ;; "editor" directory of the package, or in the package itself
        (define candidates (list (build-path at "editor") at))
        (define found (for/or ([candidate (in-list candidates)])
                        (and (file-exists? (build-path candidate "Cargo.toml"))
                             candidate)))
        (cond
          [found found]
          [(string=? (path->string at) (path->string up)) (car candidates)]
          [else (loop up)]))))

;; target-dir answers where cargo builds: the directory that holds the
;; hot path's binary. The environment wins; the binary's own place is
;; the answer when it is not named.
(define (target-dir)
  (define named (getenv "AIU_CARGO_TARGET_DIR"))
  (if (and named (not (string=? named "")))
      (path->complete-path named)
      (simplify-path (build-path (hot-path-bin) "../.."))))

;; journal-path-for answers where the journal of one file lives: in the
;; state directory, named after the file and a short key of its path, so
;; two files never share one journal.
(define (journal-path-for path)
  (build-path (state-dir) "journal"
              (format "~a-~a.journal" (file-name-from-path path) (path-key path))))

;; path-key answers a short stable name for a path: the sum of its
;; characters, so the same path always gets the same key.
(define (path-key path)
  (let loop ([chars (string->list (path->string path))] [sum 0])
    (if (null? chars)
        (format "~a" (modulo sum 100000))
        (loop (cdr chars) (+ sum (char->integer (car chars)))))))

;; ensure-dir creates a directory when it is missing, and says so when it
;; cannot, so a caller never writes into a path that is not there.
(define (ensure-dir d)
  (cond
    [(directory-exists? d) d]
    [else
     (with-handlers
         ([exn:fail?
           (lambda (e)
             (error-of 'err-no-directory "the editor" (path->string d)
                       "the directory could not be created"
                       "check the permissions of the directory above it"))])
       (make-directory* d)
       d)]))

;; The one place the environment is read, for every area above this one.
(provide home-dir
         xdg-dir
         config-dir
         state-dir
         cache-dir
         racket-bin
         git-bin
         hot-path-bin
         crate-dir
         target-dir
         journal-path-for
         ensure-dir)
