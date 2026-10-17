#lang racket/base
;; dev-link-test.rkt -- the moved-out test submodule of src/install/dev-link.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            racket/file
            racket/list
            racket/path
            racket/string
            "../../src/errors/error-type.rkt"
            "../../src/spec/spec.rkt"
         "../../src/install/dev-link.rkt")

(module+ test
  (require rackunit
           racket/file
           racket/path
           "../../src/install/activate.rkt"
           "../../src/build/build-plan.rkt"
           "../../src/install/local-perform.rkt"
           "../../src/errors/error-type.rkt"
           "../../src/spec/plan.rkt"
           "../../src/spec/spec.rkt")

  ;; All fixtures are synthetic (T-10) under one temp root: a fake
  ;; checkout, a state dir, a prefix. Nothing leaves temp.
  (define test-root (make-temporary-directory "pm-dev~a"))
  (define state (build-path test-root "state"))
  (define checkout (build-path test-root "checkout"))
  (make-directory* (build-path checkout "bin"))
  (call-with-output-file (build-path checkout "bin" "prog.sh")
    (lambda (out) (display "prog-bytes" out)))
  (call-with-output-file (build-path checkout "inc.h")
    (lambda (out) (display "inc-bytes" out)))
  (define prefix (build-path test-root "prefix"))

  ;; Link, read back, status flags dev; twice-linking refuses.
  (dev-link! "pkg-dev" checkout "tip" state)
  (check-true (dev-linked? "pkg-dev" state))
  (check-equal? (dev-status "pkg-dev" state)
                (list "pkg-dev" (path->string checkout) 'dev))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-link! "pkg-dev" checkout "tip" state)
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-link! "Bad!" checkout "tip" state)
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-link! "pkg-gone" (build-path test-root "nowhere")
                           "tip" state)
                'no-error))
  ;; Unlink releases; twice-unlink stays void; status then refuses.
  (dev-unlink! "pkg-dev" state)
  (check-false (dev-linked? "pkg-dev" state))
  (check-not-exn (lambda () (dev-unlink! "pkg-dev" state)))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-status "pkg-dev" state)
                'no-error))
  (dev-link! "pkg-dev" checkout "tip" state)

  ;; Install links prefix paths at checkout files; modes pass over.
  (dev-install! '((bin "bin/prog.sh" "bin/prog")
                  (include "inc.h" "include/inc.h")
                  (mode "bin/prog" 493))
                checkout prefix)
  (check-equal? (file->string (build-path prefix "bin" "prog"))
                "prog-bytes")
  (check-equal? (path->string (resolve-path (build-path prefix "bin" "prog")))
                (path->string (build-path checkout "bin" "prog.sh")))
  ;; Escapes, missing sources and built-tree forms refuse loudly.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-install! '((bin "x" "../escape")) checkout prefix)
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-install! '((bin "missing" "bin/missing")) checkout prefix)
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-install! '((bin "bin/prog")) checkout prefix)
                'no-error))

  ;; End to end: a dev checkout flows mark, in-place build, symlink
  ;; install, check, clear and current, then activates normally with
  ;; generation links resolving into the checkout itself.
  (define co2 (build-path test-root "co2"))
  (make-directory co2)
  (call-with-output-file (build-path co2 "build.sh")
    (lambda (out) (display "#!/bin/sh\nprintf dev-bytes > built.txt\n" out)))
  (call-with-output-file (build-path co2 "makefile")
    (lambda (out) (display "all:\n\tsh build.sh\n" out)))
  (define ver2 (build-path test-root "ver2"))
  (define cur2 (build-path test-root "cur2"))
  (dev-link! "pkg-e2e" co2 "tip" state)
  (local-perform! (list->plan (list (mark-incomplete-action
                                     (path->string ver2)))))
  (execute-build-steps (list (build-step 'make '(#:dir "."
                                                  #:targets ("all"))))
                       #:source co2 #:work co2 #:prefix ver2)
  (dev-install! '((bin "built.txt" "bin/built")) co2 ver2)
  (local-perform! (list->plan (list (check-action '("cat" "bin/built")
                                                   (path->string ver2))
                                    (clear-incomplete-action
                                     (path->string ver2))
                                    (set-current-action
                                     (path->string ver2)
                                     (path->string cur2)))))
  (check-equal? (file->string (build-path cur2 "bin" "built")) "dev-bytes")
  (define prof2 (build-path test-root "profile2"))
  (define gen-e2e (profile-activate (list (list "pkg-e2e" ver2
                                                '("bin/built")))
                                    prof2))
  (check-equal? (file->string (build-path gen-e2e "bin" "built")) "dev-bytes")
  (check-true (dev-linked? "pkg-e2e" state))
  (delete-directory/files test-root))

