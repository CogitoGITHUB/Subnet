#lang racket/base
;; update-test.rkt -- the moved-out test submodule of src/store/update.rkt.
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
            "../../src/install/activate.rkt"
            "../../src/install/apply.rkt"
            "../../src/queue/journal.rkt"
            "../../src/store/manifest.rkt"
            "../../src/git/vault.rkt"
            "../../src/errors/error-type.rkt"
            "../../src/machine/file-lock.rkt"
            "../../src/spec/plan.rkt"
            "../../src/narration/narration.rkt"
         "../../src/store/update.rkt")

(module+ test
  (require rackunit
           racket/file
           "../../src/install/activate.rkt"
           "../../test-doubles/fake-git.rkt"
           "../../src/git/git-repo.rkt"
           "../../src/store/manifest.rkt"
           "../../src/process/run.rkt"
           "../../src/git/vault.rkt"
           "../../src/git/git-env.rkt"
           "../../src/errors/error-type.rkt"
           "../../src/machine/file-lock.rkt"
           "../../src/spec/plan.rkt"
           "../../src/entry/version.rkt")

  ;; All fixtures are synthetic (T-10): a tiny upstream repo, a vault
  ;; over file:// URLs, lock entries with real pins. Nothing leaves
  ;; the temp root and no network is touched.
  (define test-root (make-temporary-directory "pm-update~a"))
  (define test-home (build-path test-root "home"))
  (make-directory test-home)
  (define (fixture-git dir . args)
    (define res
      (run-command (git-executable-path) args
                   #:cwd (path->string dir)
                   #:kind 'fetch #:operation "update-fixture"
                   #:env `(("GIT_AUTHOR_NAME" . "t")
                            ("GIT_AUTHOR_EMAIL" . "t@t")
                            ("GIT_COMMITTER_NAME" . "t")
                            ("GIT_COMMITTER_EMAIL" . "t@t")
                            ("HOME" . ,(path->string test-home))
                            ("GIT_CONFIG_NOSYSTEM" . "1"))))
    (unless (zero? (run-result-exit res))
      (error 'update-fixture "git failed: ~a" args))
    res)
  (define up (build-path test-root "upstream"))
  (make-directory up)
  (fixture-git up "init" "-b" "main" ".")
  (call-with-output-file (build-path up "f.txt")
    (lambda (out) (displayln "F" out)))
  (fixture-git up "add" "-A")
  (fixture-git up "commit" "-qm" "init")
  (define (head-now)
    (car (run-result-stdout-lines (fixture-git up "rev-parse" "HEAD"))))
  (define pin-a (head-now))
  (define vault-git (build-path test-root "vault" "vault.git"))
  (make-directory* (build-path test-root "vault"))
  (vault-init vault-git)
  (define (mkentry name commit)
    (lock-entry name (string->version "1.0") commit
                (string-append "file://" (path->string up))
                'default '() "s" "i" '()))
  (parameterize ([current-allow-file-urls #t])
    ;; Nothing new upstream: the pin still matches.
    (check-equal? (check-package (path->string vault-git)
                                 "pkg-a"
                                 (string-append "file://" (path->string up))
                                 pin-a)
                  (list "pkg-a" 'up-to-date pin-a))
    ;; One new commit upstream: behind names the remote pin.
    (call-with-output-file (build-path up "g.txt")
      (lambda (out) (displayln "G" out)))
    (fixture-git up "add" "-A")
    (fixture-git up "commit" "-qm" "second")
    (define pin-b (head-now))
    (check-equal? (check-package (path->string vault-git)
                                 "pkg-a"
                                 (string-append "file://" (path->string up))
                                 pin-a)
                  (list "pkg-a" 'behind pin-b))
    ;; An unreachable URL is a status, never a raise.
    (define bad (check-package (path->string vault-git)
                               "pkg-bad"
                               "file:///nonexistent-pm-update-test"
                               pin-a))
    (check-equal? (first bad) "pkg-bad")
    (check-equal? (second bad) 'fetch-failed)
    ;; All together: behind checks, dev and held skip without fetch.
    (profile-hold (path->string test-root) "pkg-held" "default")
    (define results
      (update-all (path->string vault-git)
                  (list (mkentry 'pkg-a pin-b)
                        (mkentry 'pkg-dev pin-a)
                        (mkentry 'pkg-held pin-a))
                  '("pkg-dev")
                  (path->string test-root)))
    (check-equal? (map second results) '(up-to-date dev-skipped held-skipped))
    (check-not-false
     (member "pkg-dev: dev-skipped (no pin to compare)"
             (update-report results))))
  ;; Apply delegates with the manifest mandatory: success records.
  (define mfile (build-path test-root "manifest.rktd"))
  (define ment (manifest-entry "pkg-a" "https://example.org/a.git"
                               "refs/vault/pkg-a" 1 #f '() #f))
  (define state (path->string (build-path test-root "state")))
  (make-directory* state)
  (define ubox (box '()))
  (parameterize ([current-fake-log ubox])
    (update-apply (list->plan (list (write-file-action "/tmp/x" "x")))
                  "hu" fake-perform!
                  #:state state #:package "pkg-a" #:slot "default"
                  #:manifest mfile #:manifest-entry ment))
  (check-equal? (manifest-read mfile) (list ment))
  (check-equal? (length (journal-completions state "pkg-a" "default")) 1)

  ;; E-16b: three fixtures in one declaration fill the vault, and a
  ;; second run reports all present. The multi-add wedge that blocked
  ;; this (frozen sequential adds in one process) no longer reproduces:
  ;; three bare vault-adds pass alone and the full suite passes, so the
  ;; batch shape is proven directly instead of staying reduced.
  (define (ff-upstream sub)
    (define d (build-path test-root sub))
    (make-directory d)
    (fixture-git d "init" "-b" "main" ".")
    (call-with-output-file (build-path d "f.txt")
      (lambda (out) (displayln "F" out)))
    (fixture-git d "add" "-A")
    (fixture-git d "commit" "-qm" "init")
    d)
  (define (fentry n d)
    (manifest-entry n (string-append "file://" (path->string d))
                    (string-append "refs/vault/" n) 1 #f '() #f))
  (define fa-manifest (build-path test-root "fetch-a.rktd"))
  (manifest-write fa-manifest (list (fentry "ff-a" (ff-upstream "ff-a"))))
  (define fvault (build-path test-root "fvault"))
  (make-directory fvault)
  (define froot (path->string (build-path fvault "vault.git")))
  (define ra
    (parameterize ([current-allow-file-urls #t])
      (pm-fetch froot fa-manifest)))
  (check-equal? (map second ra) '(new))
  (define pina (third (first ra)))
  (check-true (regexp-match? #px"^[0-9a-f]{40}$" pina))
  (define ra2
    (parameterize ([current-allow-file-urls #t])
      (pm-fetch froot fa-manifest)))
  (check-equal? ra2 (list (list "ff-a" 'present "refs/vault/ff-a")))
  (check-regexp-match #rx"ff-a: new" (car (update-report ra)))
  ;; Three at once: the declaration fills the vault in one call, and
  ;; the second run reports every one present without fetching.
  (define f3-manifest (build-path test-root "fetch-3.rktd"))
  (manifest-write f3-manifest (list (fentry "ff-1" (ff-upstream "ff-1"))
                                    (fentry "ff-2" (ff-upstream "ff-2"))
                                    (fentry "ff-3" (ff-upstream "ff-3"))))
  (define r3
    (parameterize ([current-allow-file-urls #t])
      (pm-fetch froot f3-manifest)))
  (check-equal? (map second r3) '(new new new))
  (check-true (andmap (lambda (r) (regexp-match? #px"^[0-9a-f]{40}$" (third r)))
                      r3))
  (define r32
    (parameterize ([current-allow-file-urls #t])
      (pm-fetch froot f3-manifest)))
  (check-equal? (map second r32) '(present present present))

  ;; E-16c: six fixtures at limit 3 finish with correct pins in
  ;; manifest order, and the broken URL is reported failed without
  ;; stopping the others.
  (define p-manifest (build-path test-root "fetch-p.rktd"))
  (manifest-write p-manifest
                  (for/list ([n (in-range 1 7)])
                    (fentry (format "ff-p~a" n)
                            (ff-upstream (format "ff-p~a" n)))))
  ;; The append reads back file:// URLs, so it needs the same test-only
  ;; permission the fetches do.
  (parameterize ([current-allow-file-urls #t])
    (manifest-write p-manifest
                    (append (manifest-read p-manifest)
                            (list (manifest-entry "ff-bad"
                                                  "file:///nonexistent-pm-fetch-p"
                                                  "refs/vault/ff-bad" 1 #f '() #f)))))
  (define rp
    (parameterize ([current-allow-file-urls #t])
      (pm-fetch-parallel froot p-manifest #:limit 3)))
  (check-equal? (map second rp)
                '(new new new new new new failed))
  (check-equal? (map first rp)
                '("ff-p1" "ff-p2" "ff-p3" "ff-p4" "ff-p5" "ff-p6" "ff-bad"))
  (check-true (andmap (lambda (r) (regexp-match? #px"^[0-9a-f]{40}$" (third r)))
                      (take rp 6)))
  (define rp2
    (parameterize ([current-allow-file-urls #t])
      (pm-fetch-parallel froot p-manifest #:limit 3)))
  (check-equal? (map second rp2)
                '(present present present present present present failed))
  (define fx-manifest (build-path test-root "fetch-x.rktd"))
  (manifest-write fx-manifest
                  (list (manifest-entry "ff-x" "file:///nonexistent-pm-fetch"
                                        "refs/vault/ff-x" 1 #f '() #f)))
  (define rx
    (parameterize ([current-allow-file-urls #t])
      (pm-fetch froot fx-manifest)))
  (check-equal? (map second rx) '(failed))
  (check-false (string=? (third (first rx)) ""))

  (delete-directory/files test-root))

