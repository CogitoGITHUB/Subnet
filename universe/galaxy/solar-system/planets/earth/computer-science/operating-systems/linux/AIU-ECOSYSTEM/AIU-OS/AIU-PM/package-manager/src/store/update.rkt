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
         "../install/activate.rkt"
         "../install/apply.rkt"
         "manifest.rkt"
         "../git/vault.rkt"
         "../errors/error-type.rkt"
         "./lockfile.rkt"
         "../spec/plan.rkt"
         "../narration/narration.rkt")

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
