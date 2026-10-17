#lang racket/base
;; activate-test.rkt -- the moved-out test submodule of src/install/activate.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module
;; itself: activate.rkt re-provides every name this body
;; uses, under contracts, so the four sibling modules it
;; used to require are dropped here -- requiring both would
;; be a duplicate import of the same name (D-046).

(require rackunit
         racket/contract/base
         "../../src/install/activate.rkt")

(module+ test
  (require rackunit
           racket/file
           racket/list
           racket/path
           racket/string
           json
           "../../src/errors/error-type.rkt"
           "../../src/narration/narration.rkt")

  ;; All fixtures are synthetic (T-10) under one temp root: two fake
  ;; package trees plus a profile dir. Nothing touches the real home.
  (define test-root (build-path (find-system-path 'temp-dir)
                                "pm-activate-test"))
  (when (directory-exists? test-root)
    (delete-directory/files test-root))
  (define (pkgfile pkg . rels)
    (define p (apply build-path test-root pkg rels))
    (make-directory* (or (path-only p) test-root))
    (call-with-output-file p (lambda (out) (display "x" out))))
  (pkgfile "a" "bin" "prog")
  (pkgfile "a" "lib" "liba.a")
  (pkgfile "b" "bin" "other")
  (pkgfile "b" "share" "doc.txt")
  (pkgfile "c" "bin" "prog")
  (define prof (build-path test-root "profile"))
  (define (entry pkg)
    (list pkg
          (build-path test-root pkg)
          (map path->string
               (map (lambda (r) (apply build-path r))
                    (if (equal? pkg "a")
                        '(("bin" "prog") ("lib" "liba.a"))
                        (if (equal? pkg "b")
                            '(("bin" "other") ("share" "doc.txt"))
                            '(("bin" "prog"))))))))

  ;; Activate one package: generation 001 with resolving links, the
  ;; profile link flipped to it.
  (define gen1 (profile-activate (list (entry "a")) prof))
  (check-true (link-exists? (build-path gen1 "bin" "prog")))
  (check-equal? (path->string (resolve-path (build-path gen1 "bin" "prog")))
                (path->string (build-path test-root "a" "bin" "prog")))
  (check-equal? (path->string (resolve-path (build-path prof "profile")))
                (path->string gen1))
  ;; G-04: the generation records the ledger it was built from.
  (define ledger1
    (call-with-input-file (build-path gen1 "ledger.rktd") read))
  (check-equal? (car ledger1) 'ledger)
  (define prog-triple
    (for/first ([t (in-list (cdr ledger1))]
                #:when (and (list? t) (= 3 (length t))
                            (equal? (third t) "bin/prog")))
      t))
  (check-true (and prog-triple (equal? (first prog-triple) "a")))

  ;; A second generation keeps the first and moves the profile link.
  (define gen2 (profile-activate (list (entry "a") (entry "b")) prof))
  (check-equal? (length (profile-generations prof)) 2)
  (check-equal? (path->string (resolve-path (build-path prof "profile")))
                (path->string gen2))

  ;; G-10: provenance. Activate inside a run with an interface and
  ;; specs; the generation records the run id, and the feed of that id
  ;; holds the activate decision, so the two reconstruct each other. A
  ;; separate profile dir, so this scenario's generations never change
  ;; the counts the rollback and remove scenarios below assert.
  (define prof10 (build-path test-root "profile-g10"))
  (define feed-dir (build-path test-root "events-g10"))
  (make-directory* feed-dir)
  (define prov-gen
    (parameterize ([verbose-screen? #f])
      (define id (begin-run! #:who 'test #:events-dir feed-dir))
      (define g (profile-activate (list (entry "a")) (path->string prof10)
                                  #:interface "test-cli"
                                  #:specs '("specs/pkg-a.rktd")))
      (end-run! "done")
      (list id g)))
  (define prov-id (first prov-gen))
  (define prov-gens (profile-generations (path->string prof10)))
  (define prov-entry
    (for/first ([g (in-list prov-gens)]
                #:when (equal? (path->string (first g))
                               (path->string (second prov-gen))))
      g))
  (check-true (and prov-entry (list? (second prov-entry))))
  (check-equal? (first (second prov-entry)) prov-id)
  (check-equal? (second (second prov-entry)) "test-cli")
  (check-equal? (third (second prov-entry)) '("specs/pkg-a.rktd"))
  (define feed-text
    (for/fold ([acc ""])
              ([f (in-list (directory-list feed-dir))]
               #:when (regexp-match? #rx"\\.jsonl$" (path->string f)))
      (string-append acc (file->string (build-path feed-dir f)))))
  (check-true (regexp-match? #rx"START" feed-text))
  (check-true (regexp-match? (regexp-quote prov-id) feed-text))
  (check-equal? (path->string (resolve-path (build-path gen2 "bin" "other")))
                (path->string (build-path test-root "b" "bin" "other")))

  ;; Two packages claiming one path fail closed with kind 'activate:
  ;; names the file, both sides, and changes nothing.
  (define before (resolve-path (build-path prof "profile")))
  (define conflict-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (profile-activate (list (entry "a") (entry "c")) prof)
      'no-error))
  (check-pred activate-error? conflict-err)
  (check-regexp-match #rx"file conflict, nothing changed"
                      (exn-message conflict-err))
  (check-regexp-match #rx"owned-by: a" (exn-message conflict-err))
  (check-regexp-match #rx"claimed-by: c" (exn-message conflict-err))
  (check-equal? (length (profile-generations prof)) 2)
  (check-equal? (resolve-path (build-path prof "profile")) before)

  ;; Empty activation, escaping rels and missing targets refuse.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-activate '() prof)
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-activate (list (list "a" (build-path test-root "a")
                                              '("../x")))
                                  prof)
                'no-error))
  (check-pred activate-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-activate (list (list "a" (build-path test-root "a")
                                              '("bin" "gone")))
                                  prof)
                'no-error))

  ;; E-15: remove builds a generation minus the package and frees no
  ;; disk. Owner naming reads store-layout targets, so these fixtures
  ;; live under a synthetic store (E-19 extends naming to dev trees).
  (define sroot (build-path test-root "store15"))
  (define (spkgfile pkg rel)
    (define p (build-path sroot "store" pkg "default" "1.0-x" rel))
    (make-directory* (or (path-only p) sroot))
    (call-with-output-file p (lambda (out) (display "x" out))))
  (spkgfile "sa" "bin/prog")
  (spkgfile "sb" "bin/other")
  (define (sentry pkg rel)
    (list pkg (build-path sroot "store" pkg "default" "1.0-x") (list rel)))
  (define prof15 (build-path test-root "profile15"))
  (define g15
    (profile-activate (list (sentry "sa" "bin/prog")
                            (sentry "sb" "bin/other"))
                      prof15))
  (define g15b (profile-remove prof15 "sb" (list (sentry "sa" "bin/prog"))))
  (check-false (link-exists? (build-path g15b "bin" "other")))
  (check-true (link-exists? (build-path g15b "bin" "prog")))
  (check-true (file-exists? (build-path sroot "store" "sb" "default"
                                         "1.0-x" "bin" "other")))
  (check-equal? (path->string (resolve-path (build-path prof15 "profile")))
                (path->string g15b))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-remove prof15 "zzz" (list (sentry "sa" "bin/prog")))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-remove prof15 "sa" (list (sentry "sa" "bin/prog")
                                                  (sentry "sb" "bin/other")))
                'no-error))
  ;; Removing the last package deletes the link; the store is intact.
  (check-equal? (profile-remove prof15 "sa" '()) prof15)
  (check-false (link-exists? (build-path prof15 "profile")))
  (check-true (file-exists? (build-path sroot "store" "sa" "default"
                                         "1.0-x" "bin" "prog")))

  ;; Rollback repoints at a numbered generation; unknown N refuses.
  ;; Generations stay on disk: the list itself is the rollback state.
  (profile-rollback prof 1)
  (check-equal? (path->string (resolve-path (build-path prof "profile")))
                (path->string gen1))
  (check-equal? (length (profile-generations prof)) 2)
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-rollback prof 9)
                'no-error))

  ;; Hold pins a slot idempotently; unhold releases it the same way.
  (check-false (profile-held? prof "a" "default"))
  (profile-hold prof "a" "default")
  (check-true (profile-held? prof "a" "default"))
  (profile-hold prof "a" "default")
  (check-true (profile-held? prof "a" "default"))
  (profile-unhold prof "a" "default")
  (check-false (profile-held? prof "a" "default"))
  (profile-unhold prof "a" "default")
  (check-false (profile-held? prof "a" "default"))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-hold prof "" "default")
                'no-error))

  ;; G-05 (DEFAULT: last 5, holds and the live link are absolute).
  ;; Seven generations, live rolled back to the oldest: gc keeps the
  ;; newest five plus the live one, and says so per generation.
  (define gprof (build-path test-root "profile-gc"))
  (for ([i (in-range 7)])
    (profile-activate (list (entry "a")) (path->string gprof)))
  (profile-rollback (path->string gprof) 1)
  (define-values (kept doomed)
    (apply values (profile-gc (path->string gprof) #:keep 5)))
  (check-equal? (length kept) 6)
  (check-equal? (length doomed) 1)
  (check-equal? (map (lambda (g) (path->string (file-name-from-path g)))
                     doomed)
                '("profile-002"))
  (check-false (directory-exists? (build-path gprof "profile-002")))
  (check-true (directory-exists? (build-path gprof "profile-001")))
  ;; Held packages pin their generation: every generation here holds
  ;; pkg h, so with keep 2 the oldest still survives by held status.
  (define hprof (build-path test-root "profile-gch"))
  (define hstore (build-path test-root "store" "h" "default" "1.0"))
  (make-directory* (build-path hstore "bin"))
  (call-with-output-file (build-path hstore "bin" "prog")
    (lambda (out) (display "x" out)))
  (for ([i (in-range 3)])
    (profile-activate (list (list "h" (path->string hstore) '("bin/prog")))
                      (path->string hprof)))
  (profile-hold (path->string hprof) "h" "default")
  (define-values (hkept hdoomed)
    (apply values (profile-gc (path->string hprof) #:keep 1)))
  (check-equal? (length hkept) 3)
  (check-equal? hdoomed '())
  (delete-directory/files test-root))

