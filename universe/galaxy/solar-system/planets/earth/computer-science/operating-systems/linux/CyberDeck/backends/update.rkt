#lang racket/base
;; update.rkt -- check, review, skip and apply-delegate (E-16). Own
;; module per ENGINE.org: review logic lives here, not in core or cli.
;;
;; check-package fetches a namespace (vault-add reports the remote
;; pin) and compares it to the lock pin: up-to-date, behind, or
;; fetch-failed. A cancelled fetch is never swallowed. update-all
;; classifies a lockfile: dev packages skip without fetching (they
;; have no pin to compare, DEV-MODE), held slots skip without
;; fetching, the rest check for real. update-report renders one info
;; line per package. update-apply delegates effects to apply-plan
;; with the manifest MANDATORY (updates always record); it adds no
;; machinery of its own. Exit codes never change on skips: skips are
;; data, and a run of pure skips still returns normally.

(require racket/contract/base
         racket/file
         racket/list
         "activate.rkt"
         "apply.rkt"
         "journal.rkt"
         "manifest.rkt"
         "vault.rkt"
         "../core/errors.rkt"
         "../core/lock.rkt"
         "../core/plan.rkt")

(provide
 (contract-out
  ;; path-string string string string -> result, fetch plus compare
  [check-package (-> path-string? string? string? string?
                     (list/c string? symbol? string?))]
  ;; path-string lockentries strings path-string -> results, skips kept
  [update-all (-> path-string? (listof lock-entry?) (listof string?)
                  path-string?
                  (listof (list/c string? symbol? string?)))]
  ;; results -> strings, one info line per package
  [update-report (-> (listof (list/c string? symbol? string?))
                     (listof string?))]
  ;; plan string performer -> void, apply with mandatory manifest
  [update-apply (->* (plan? string? (-> action? void?)
                            #:state path-string?
                            #:package string?
                            #:slot string?
                            #:manifest path-string?
                            #:manifest-entry manifest-entry?)
                     (#:writer (or/c #f (list/c string? string?))
                      #:cancel (or/c evt? #f))
                     void?)]))

;; path-string string string string -> result, fetch plus compare.
;; cancelled escapes; every other pm failure becomes fetch-failed.
(define (check-package vault-root name url pin)
  (with-handlers ([exn:fail:pm?
                   (lambda (e)
                     (if (cancelled-error? e)
                         (raise e)
                         (list name 'fetch-failed (exn-message e))))])
    (define remote
      (vault-add-result-pin
       (vault-add vault-root name url #:fsck-allow '())))
    (if (equal? remote pin)
        (list name 'up-to-date pin)
        (list name 'behind remote))))

;; path-string lockentries strings path-string -> results. Dev and
;; held packages skip without fetching; the rest check for real.
(define (update-all vault-root entries dev-names profile-root)
  (for/list ([e (in-list entries)])
    (define name (symbol->string (lock-entry-name e)))
    (define slot (symbol->string (lock-entry-slot e)))
    (cond [(member name dev-names)
           (list name 'dev-skipped "no pin to compare")]
          [(profile-held? profile-root name slot)
           (list name 'held-skipped "slot pinned")]
          [else
           (check-package vault-root name
                          (lock-entry-url e) (lock-entry-commit e))])))

;; results -> strings, one info line per package, input order kept
(define (update-report results)
  (for/list ([r (in-list results)])
    (format "~a: ~a (~a)" (first r) (second r) (third r))))

;; plan string performer -> void, apply with mandatory manifest
(define (update-apply p input-hash performer
                      #:state state
                      #:package package
                      #:slot slot
                      #:manifest manifest
                      #:manifest-entry entry
                      #:writer [writer #f]
                      #:cancel [cancel #f])
  (apply-plan p input-hash performer
              #:state state
              #:package package
              #:slot slot
              #:manifest manifest
              #:manifest-entry entry
              #:writer writer
              #:cancel cancel))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           "activate.rkt"
           "fake.rkt"
           "git.rkt"
           "manifest.rkt"
           "run.rkt"
           "vault.rkt"
           "../core/git-url.rkt"
           "../core/errors.rkt"
           "../core/lock.rkt"
           "../core/plan.rkt"
           "../core/version.rkt")

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
  (delete-directory/files test-root))
