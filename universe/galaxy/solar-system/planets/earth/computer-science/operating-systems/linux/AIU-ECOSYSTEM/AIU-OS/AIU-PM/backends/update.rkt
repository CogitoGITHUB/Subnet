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
                (listof (list/c string? symbol? string?)))]
  ;; path-string path-string -> results, the same fetch concurrent
  [pm-fetch-parallel (->* (path-string? path-string?)
                          (#:limit exact-positive-integer?)
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

;; E-16c: the same fetch, concurrent. One thread per missing package,
;; at most LIMIT in flight; each thread waits only on its own fetch,
;; and one failure never stops the others. The vault write path stays
;; SERIALIZED through a process-wide gate semaphore admitting one
;; vault-add at a time, with the existing try-only writer lock inside
;; vault-add as the backstop rather than the mechanism. Recorded after
;; reading vault.rkt and vault-lock: one shared bare repo plus try-only
;; locks means threads bound in-flight work and isolate failures; they
;; do not speed the vault itself. Results come back in manifest order,
;; never in finish order, so the summary is deterministic.
(define fetch-vault-gate (make-semaphore 1))

(define (pm-fetch-parallel vault-root manifest-path #:limit [limit 4])
  (with-op 'fetch (as-text manifest-path)
           (format "every missing package is fetched, at most ~a at once"
                   limit)
           (lambda ()
             (unless (directory-exists? vault-root)
               (vault-init vault-root))
             (define present
               (with-handlers ([exn:fail:pm? (lambda (e) '())])
                 (vault-list vault-root)))
             (define missing
               (filter (lambda (e)
                         (not (member (manifest-entry-name e) present)))
                       (manifest-read manifest-path)))
             (for ([e (in-list missing)])
               (skip 'fetch (manifest-entry-name e)
                     "parallel fetch defers the per-package reason to its thread"))
             (define sema (make-semaphore limit))
             (define slots
               (for/list ([e (in-list missing)])
                 (define slot-box (box #f))
                 (cons e slot-box)))
             (define threads
               (for/list ([s (in-list slots)])
                 (thread
                  (lambda ()
                    (call-with-semaphore
                     sema
                     (lambda ()
                       (define e (car s))
                       ;; The gate serializes the vault writes; the
                       ;; in-flight bound above is what stays parallel.
                       (call-with-semaphore
                        fetch-vault-gate
                        (lambda ()
                          (set-box! (cdr s)
                                    (fetch-new vault-root
                                               (manifest-entry-name e)
                                               (manifest-entry-url e)))))))))))
             ;; Each join waits only on its own thread: no polling, no
             ;; timers, and a failure in one slot never touches another.
             (for ([th (in-list threads)]) (thread-wait th))
             (define done
               (for/hash ([s (in-list slots)])
                 (values (manifest-entry-name (car s)) (unbox (cdr s)))))
             ;; Manifest order, never finish order, so the summary is
             ;; deterministic no matter which thread won the race.
             (for/list ([e (in-list (manifest-read manifest-path))])
               (define name (manifest-entry-name e))
               (if (member name present)
                   (resolve-present name)
                   (hash-ref done name))))))

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
