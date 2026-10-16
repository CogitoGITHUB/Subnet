#lang racket/base
;; activate.rkt -- the public promise for profile generations: the
;; atomic profile swap and everything around it (ENGINE.org
;; backends/activate.rkt, SPEC-NEUTRAL section 4, E-13). Generations
;; are profile-NNN/ dirs of absolute symlinks; activate validates
;; everything first, builds the next generation, then flips the
;; profile link with store.rkt's atomic swap: a conflict fails closed
;; with kind 'activate (exit 9) before anything changes. E-15's
;; rollback and remove are here too; hold pins slots in
;; profile/holds.rktd.
;;
;; This facade must not add logic of its own; the jobs live in
;; generation.rkt, profile-flip.rkt, profile-gc.rkt and
;; profile-holds.rkt. The contracts stay HERE, on the entry point, so
;; blame lands on the caller of profile-activate and not on the module
;; that happens to hold the definition.
;;
;; The suite below is promise-level, end to end across all four
;; modules; step 14 moves inline tests to package-manager/tests/.

(require racket/contract/base
         "generation.rkt"
         "profile-flip.rkt"
         "profile-gc.rkt"
         "profile-holds.rkt")

(provide
 (contract-out
  ;; (listof entry) path-string -> path, next generation, profile flips
  [profile-activate (->* ((listof (list/c string? path-string?
                                          (listof string?)))
                          path-string?)
                         (#:interface string?
                          #:specs (listof string?)
                          #:lock (or/c string? #f))
                         path?)]
  ;; path-string -> (listof (gen provenance)), oldest first; provenance
  ;; is #f for generations predating it, else (run-id interface specs lock)
  [profile-generations (-> path-string?
                           (listof (list/c path? (or/c #f (list/c (or/c string? #f)
                                                                  string?
                                                                  (listof string?)
                                                                  (or/c string? #f))))))]
  ;; generation dir -> provenance or #f, never raises
  [generation-provenance (-> path-string?
                             (or/c #f (list/c (or/c string? #f)
                                              string?
                                              (listof string?)
                                              (or/c string? #f))))]
  ;; path-string exact-integer -> path, repoint profile at generation N
  [profile-rollback (-> path-string? exact-integer? path?)]
  ;; path-string string (listof entry) -> path, generation minus one
  [profile-remove (-> path-string? string?
                      (listof (list/c string? path-string?
                                      (listof string?)))
                      path?)]
  ;; path-string string string -> void, pin a slot against updates
  [profile-hold (-> path-string? string? string? void?)]
  ;; path-string string string -> void, release a slot pin
  [profile-unhold (-> path-string? string? string? void?)]
  ;; path-string string string -> boolean, is the slot pinned
  [profile-held? (-> path-string? string? string? boolean?)]
  ;; path-string -> path, where the profile link points today
  [current-generation (-> path-string? path?)]
  ;; path-string -> (listof (name slot)), absent reads as none held
  [read-holds (-> path-string? (listof (list/c string? string?)))]
  ;; path-string -> (kept deleted), G-05 prunes generations
  [profile-gc (->* (path-string?)
                   (#:keep exact-positive-integer?)
                   (list/c (listof path?) (listof path?)))]))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/list
           racket/path
           racket/string
           json
           "../errors/error-type.rkt"
           "../narration/narration.rkt")

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
