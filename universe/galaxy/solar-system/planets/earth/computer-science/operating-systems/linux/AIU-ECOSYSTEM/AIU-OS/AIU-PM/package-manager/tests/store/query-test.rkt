#lang racket/base
;; query-test.rkt -- the moved-out test submodule of src/store/query.rkt.
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
            "../../src/install/activate.rkt"
            "../../src/store/manifest.rkt"
            "../../src/git/vault.rkt"
            "../../src/errors/error-type.rkt"
            "../../src/machine/file-lock.rkt"
            "../../src/spec/plan.rkt"
            "../../src/entry/version.rkt"
            "../../src/narration/narration.rkt"
         "../../src/store/query.rkt")

(module+ test
  (require rackunit
           racket/file
           racket/path
           "../../src/git/git-repo.rkt"
           "../../src/store/manifest.rkt"
           "../../src/process/run.rkt"
           "../../src/errors/error-type.rkt"
           "../../src/git/git-env.rkt"
           "../../src/machine/file-lock.rkt"
           "../../src/entry/version.rkt")

  ;; All fixtures are synthetic (T-10) under one temp root: a lock plus
  ;; manifest entry, a profile generation with links, a vault holding
  ;; one pin plus a current tree to compare. Nothing leaves temp.
  (define test-root (make-temporary-directory "pm-query~a"))
  (define test-lock
    (list (lock-entry 'pkg-a (string->version "1.0")
                      (make-string 40 #\a)
                      "https://example.org/a.git"
                      'default '((gui . #t)) "s" "i" '())))
  (define test-manifest
    (list (manifest-entry "pkg-a" "https://example.org/a.git"
                          "refs/vault/pkg-a" 1 #f '() #f)))

  ;; why names spec, slot, flags and pin; unknown names refuse.
  (define why (query-why test-lock test-manifest "pkg-a"))
  (check-equal? (list (first why) (second why) (third why))
                '("pkg-a" "1.0" "default"))
  (check-equal? (fourth why) '((gui . #t)))
  (check-regexp-match #rx"pkg-a 1.0 \\[default\\]" (why->text why))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (query-why test-lock test-manifest "pkg-nope")
                'no-error))

  ;; owner reports the claim on a taken path, nothing on a free one.
  (define store-a (build-path test-root "store" "pkg-a" "default" "1.0-x"))
  (make-directory* (build-path store-a "bin"))
  (call-with-output-file (build-path store-a "bin" "prog")
    (lambda (out) (display "x" out)))
  (define prof (build-path test-root "profile"))
  (define gen1 (build-path prof "profile-001"))
  (make-directory* (build-path gen1 "bin"))
  (make-file-or-directory-link (path->string (build-path store-a "bin" "prog"))
                               (build-path gen1 "bin" "prog"))
  (make-file-or-directory-link (path->string gen1)
                               (build-path prof "profile"))
  (define claim (query-owner (path->string prof) "bin/prog"))
  (check-equal? (first claim) "pkg-a")
  (check-equal? (second claim)
                (path->string (build-path store-a "bin" "prog")))
  (check-regexp-match #rx"owned by pkg-a"
                      (owner->text claim "bin/prog"))
  (check-false (query-owner (path->string prof) "bin/free"))
  (check-equal? (owner->text #f "bin/free") "bin/free is free")
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (query-owner (path->string prof) "/abs/path")
                'no-error))

  ;; G-04: with a ledger present, the ledger answers even when the tree
  ;; has diverged. Repoint the link after the fact; the record still
  ;; names the original owner.
  (define gen2 (build-path prof "profile-002"))
  (make-directory* (build-path gen2 "bin"))
  (define store-b (build-path test-root "store" "pkg-b" "default" "1.0-x"))
  (make-directory* (build-path store-b "bin"))
  (call-with-output-file (build-path store-b "bin" "prog")
    (lambda (out) (display "y" out)))
  (make-file-or-directory-link (path->string (build-path store-a "bin" "prog"))
                               (build-path gen2 "bin" "prog"))
  (call-with-output-file (build-path gen2 "ledger.rktd")
    (lambda (out)
      ;; One triple per owned path: (ledger (NAME DIR REL) ...), the
      ;; same shape build-generation! writes.
      (write `(ledger ("pkg-a" ,(path->string (build-path store-a "bin" "prog"))
                                 "bin/prog"))
             out)))
  (delete-file (build-path prof "profile"))
  (make-file-or-directory-link (path->string gen2)
                               (build-path prof "profile"))
  ;; Diverge the tree: the link now points at pkg-b, but the ledger
  ;; still says pkg-a, and the ledger wins.
  (delete-file (build-path gen2 "bin" "prog"))
  (make-file-or-directory-link (path->string (build-path store-b "bin" "prog"))
                               (build-path gen2 "bin" "prog"))
  (define ledged (query-owner (path->string prof) "bin/prog"))
  (check-equal? (first ledged) "pkg-a")
  (check-equal? (second ledged)
                (path->string (build-path store-a "bin" "prog")))

  ;; G-11: status answers installed from a real activation, held from a
  ;; real hold. Activate pkg-a through profile-activate so a ledger
  ;; exists, hold its slot, then read both back.
  (define prof3 (build-path test-root "profile3"))
  (profile-activate (list (list "pkg-a" (path->string store-a)
                                '("bin/prog")))
                    (path->string prof3))
  (define status-locks
    (list (lock-entry 'pkg-a (string->version "1.0")
                      (make-string 40 #\a) "https://example.org/a.git"
                      'default '() "s" "i" '())))
  (define rows (query-status (path->string prof3) status-locks))
  (check-equal? (length rows) 1)
  (check-equal? (take (first rows) 3) '("pkg-a" "1.0" "default"))
  (check-false (fourth (first rows)))
  (check-equal? (fifth (first rows)) '("bin/prog"))
  (profile-hold (path->string prof3) "pkg-a" "default")
  (check-equal? (query-held (path->string prof3))
                '(("pkg-a" "default")))
  (define held-rows (query-status (path->string prof3) status-locks))
  (check-true (fourth (first held-rows)))
  ;; No lock entry: version and slot read unknown, held is false rather
  ;; than an error, because status must answer even mid-migration.
  (define unknown-rows (query-status (path->string prof3) '()))
  (check-equal? (take (first unknown-rows) 3)
                '("pkg-a" "unknown" "unknown"))
  (check-false (fourth (first unknown-rows)))

  ;; verify compares the current tree against its pin, byte by byte.
  (define up (build-path test-root "upstream"))
  (make-directory up)
  (define home (build-path test-root "home"))
  (make-directory home)
  (define (qgit dir . args)
    (define res
      (run-command (git-executable-path) args
                   #:cwd (path->string dir)
                   #:kind 'fetch #:operation "query-fixture"
                   #:env `(("GIT_AUTHOR_NAME" . "t")
                            ("GIT_AUTHOR_EMAIL" . "t@t")
                            ("GIT_COMMITTER_NAME" . "t")
                            ("GIT_COMMITTER_EMAIL" . "t@t")
                            ("HOME" . ,(path->string home))
                            ("GIT_CONFIG_NOSYSTEM" . "1"))))
    (unless (zero? (run-result-exit res))
      (error 'query-fixture "git failed: ~a" args))
    res)
  (qgit up "init" "-b" "main" ".")
  (call-with-output-file (build-path up "f.txt")
    (lambda (out) (displayln "F" out)))
  (qgit up "add" "-A")
  (qgit up "commit" "-qm" "init")
  (define vg (build-path test-root "vault" "vault.git"))
  (make-directory* (build-path test-root "vault"))
  (vault-init vg)
  (define vpin
    (parameterize ([current-allow-file-urls #t])
      (vault-add-result-pin
       (vault-add vg "pkg-a" (string-append "file://" (path->string up))))))
  (define cur (build-path test-root "current"))
  (make-directory cur)
  (vault-export-commit vg "pkg-a" vpin cur)
  (check-equal? (query-verify (path->string vg) (path->string cur)
                              "pkg-a" vpin)
                (list "pkg-a" #t '()))
  (call-with-output-file (build-path cur "f.txt")
    (lambda (out) (display "changed" out))
    #:exists 'truncate/replace)
  (define bad (query-verify (path->string vg) (path->string cur)
                            "pkg-a" vpin))
  (check-false (second bad))
  (check-not-false (member "changed: f.txt" (third bad)))
  (check-regexp-match #rx"MISMATCH" (verify->text bad))
  (check-equal? (verify->text (list "pkg-a" #t '())) "pkg-a: verified")
  ;; G-03: the stage refuses. A clean tree passes silently; a tampered
  ;; one raises kind 'verify, which exits 6.
  (define cur2 (build-path test-root "current2"))
  (make-directory cur2)
  (vault-export-commit vg "pkg-a" vpin cur2)
  (check-true (with-handlers ([exn:fail:pm? (lambda (e) #f)])
                (verify-tree! (path->string vg) (path->string cur2)
                              "pkg-a" vpin)
                #t))
  (call-with-output-file (build-path cur2 "f.txt")
    (lambda (out) (display "tampered" out))
    #:exists 'truncate/replace)
  (define tampered-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (verify-tree! (path->string vg) (path->string cur2) "pkg-a" vpin)
      'no-error))
  (check-pred verify-error? tampered-err)
  (check-equal? (pm-error-exit-code tampered-err) 6)
  ;; The source still resolves to the pin, so the source stage passes;
  ;; move upstream one commit and it refuses too.
  (parameterize ([current-allow-file-urls #t])
    (check-true (with-handlers ([exn:fail:pm? (lambda (e) #f)])
                  (verify-source! (path->string vg) "pkg-a"
                                  (string-append "file://" (path->string up))
                                  vpin)
                  #t)))
  (call-with-output-file (build-path up "g.txt")
    (lambda (out) (displayln "G" out)))
  (qgit up "add" "-A")
  (qgit up "commit" "-qm" "second")
  (define moved-err
    (parameterize ([current-allow-file-urls #t])
      (with-handlers ([exn:fail:pm? (lambda (e) e)])
        (verify-source! (path->string vg) "pkg-a"
                        (string-append "file://" (path->string up)) vpin)
        'no-error)))
  (check-pred verify-error? moved-err)
  (check-equal? (pm-error-exit-code moved-err) 6)
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (query-verify (path->string vg) "/nonexistent-pm-query"
                              "pkg-a" vpin)
                'no-error))
  (delete-directory/files test-root))

