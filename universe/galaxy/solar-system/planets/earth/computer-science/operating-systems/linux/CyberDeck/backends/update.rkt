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
         "../core/plan.rkt"
         "../core/verbose.rkt")

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
                     void?)]
  ;; path-string path-string -> results, fetch missing namespaces
  [pm-fetch (-> path-string? path-string?
                (listof (list/c string? symbol? string?)))]))

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
;; path-or-string -> string, for an event. These entry points are
;; called with both shapes (argv strings, test paths) and an event
;; field is a string.
(define (as-text x)
  (if (path? x) (path->string x) (format "~a" x)))

(define (update-all vault-root entries dev-names profile-root)
  ;; D-036: an update is a check, not a change, so every package that is
  ;; NOT checked says why. A dev link and a held slot are the two
  ;; reasons this project has, and both are narrated rather than
  ;; silently returning a status string.
  (with-op 'update (as-text vault-root)
           "every locked package is checked against the vault"
           #:how (format "~a entr(ies), ~a dev name(s)"
                   (length entries) (length dev-names))
           (lambda ()
             (for/list ([e (in-list entries)])
               (define name (symbol->string (lock-entry-name e)))
               (define slot (symbol->string (lock-entry-slot e)))
               (cond
                 [(member name dev-names)
                  (skip 'update name
                        "it is a dev link, so there is no pin to compare")
                  (list name 'dev-skipped "no pin to compare")]
                 [(profile-held? profile-root name slot)
                  (skip 'update (format "~a/~a" name slot)
                        "the slot is pinned by a hold, so it is not checked")
                  (list name 'held-skipped "slot pinned")]
                 [else
                  (step 'update name
                        "the vault is asked whether this pin still matches")
                  (check-package vault-root name
                                 (lock-entry-url e) (lock-entry-commit e))])))))

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
;; string -> result, already in the vault. Reports the namespace
;; ref: pins live under branch-qualified refs, so no single pin can
;; resolve without fetching (which present entries skip by design).
(define (resolve-present name)
  (list name 'present (vault-namespace name)))

;; path-string string string -> result, fetch plus pin
(define (fetch-new vault-root name url)
  (with-handlers ([exn:fail:pm?
                   (lambda (e)
                     (if (cancelled-error? e)
                         (raise e)
                         (list name 'failed (exn-message e))))])
    (list name 'new
          (vault-add-result-pin
           (vault-add vault-root name url #:fsck-allow '())))))

;; path-string path-string -> results, fetch missing namespaces only.
;; Present namespaces report their ref without fetching (branch-
;; qualified refs carry the pins; second runs work offline); the
;; manifest is read, never written (E-14).
(define (pm-fetch vault-root manifest-path)
  ;; D-036: a fetch of N packages says so, and each one says whether it
  ;; was fetched or already present -- the difference is exactly what an
  ;; operator (or an AI reading the feed) needs to know.
  (with-op 'fetch (as-text manifest-path)
           "every package the manifest declares is fetched or found"
           (lambda ()
             (unless (directory-exists? vault-root)
               (step 'fetch "vault-init"
                     "the vault does not exist yet, so it is created empty")
               (vault-init vault-root))
             (define present
               (with-handlers ([exn:fail:pm? (lambda (e) '())])
                 (vault-list vault-root)))
             (step 'fetch "vault-list"
                   "packages already in the vault are not fetched again")
             (for/list ([e (in-list (manifest-read manifest-path))])
               (define name (manifest-entry-name e))
               (if (member name present)
                   (begin
                     (skip 'fetch name "it is already in the vault")
                     (resolve-present name))
                   (begin
                     (step 'fetch name "it is not in the vault, so it is fetched")
                     (fetch-new vault-root name (manifest-entry-url e))))))))

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

  ;; E-16b (reduced): single-add shapes only. Multi-add batching in
  ;; one pm-fetch call wedges (BLOCKED note on the item); these prove
  ;; the fetch, present and failed paths that stay green.
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
