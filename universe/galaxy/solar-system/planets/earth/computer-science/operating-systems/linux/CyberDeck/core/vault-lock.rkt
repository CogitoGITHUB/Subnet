#lang racket/base
;; lock.rkt -- try-only locks: process-local semaphore plus fcntl file lock.
;; fcntl locks belong to the PROCESS (a same-process re-acquire silently
;; succeeds, proven in the REPL), so a process-local semaphore provides the
;; real same-process exclusion while the file lock excludes other
;; processes. Both are attempted ONCE, never waited on: contention fails
;; at once naming the holder (D-015). Timestamps are data, never decisions.

(require racket/contract/base
         racket/file
         "errors.rkt")

(provide
 (struct-out holder)
 (contract-out
  ;; vault-root holder-id holder-note thunk -> any, try once, fail naming holder
  ;; [#:on-stale-holder] fired with the displaced record when a foreign
  ;; owner record predates this acquisition (previous holder died; Racket
  ;; locks self-heal on death, so acquisition succeeds and reports)
  [call-with-vault-lock
   (->* (path-string? string? string? (-> any/c))
        (#:on-stale-holder (or/c (-> holder? any/c) #f))
        any/c)]))

;; ---------------------------------------------------------------------------
;; State (process-local exclusion table)

(struct holder (id note started) #:prefab)
;; id      : string?  who claims the lock (job id or "interactive")
;; note    : string?  what it is doing (package op)
;; started : exact-integer?  seconds data for reports, never decisions

(struct entry (sema held) #:transparent)
;; sema : semaphore?  process-local exclusion, try-only
;; held : (box/c (or/c holder? #f))  current holder record, informational

(define table-guard (make-semaphore 1))
(define table (make-hash))

;; path -> entry, creating the process-local record on first use
(define (table-entry lock-path)
  (semaphore-wait table-guard)
  (define e (hash-ref! table lock-path
                       (lambda () (entry (make-semaphore 1) (box #f)))))
  (semaphore-post table-guard)
  e)

;; path -> string, sibling lock file (never inside the bare repo itself)
(define (vault-lock-path vault-root)
  (define-values (base _name _dir?) (split-path vault-root))
  (build-path base "vault.lock"))

;; path -> path, informational owner record beside the lock
(define (vault-owner-path vault-root)
  (string->path
   (string-append (path->string (vault-lock-path vault-root)) ".owner")))

;; ---------------------------------------------------------------------------
;; Owner record (informational; liveness is the lock itself)

;; string string string -> void, atomic write of the holder record
(define (write-owner-file vault-root id note)
  (define tmp (string-append (path->string (vault-owner-path vault-root))
                             ".tmp"))
  (call-with-output-file tmp
    (lambda (out) (write (holder id note (current-seconds)) out))
    #:exists 'truncate/replace)
  (rename-file-or-directory tmp (vault-owner-path vault-root) #t))

;; string -> (or/c holder #f), never raises (a torn record reads as absent)
(define (read-owner-file vault-root)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define v (call-with-input-file (vault-owner-path vault-root) read))
    (if (holder? v) v #f)))

;; string -> void, best effort (absence is fine)
(define (remove-owner-file vault-root)
  (with-handlers ([exn:fail:filesystem? (lambda (_) (void))])
    (delete-file (vault-owner-path vault-root))))

;; string (or/c holder #f) -> never returns, kind 'config naming the holder
(define (raise-busy vault-root held)
  (raise-pm-error 'config 'call-with-vault-lock "vault busy"
                  #:fields `(("vault" . ,(if (path? vault-root)
                                             (path->string vault-root)
                                             vault-root))
                             ("holder" . ,(if held
                                              (format "~a (~a, started ~a)"
                                                      (holder-id held)
                                                      (holder-note held)
                                                      (holder-started held))
                                              "unknown (no owner record; live foreign holder?)")))))

;; ---------------------------------------------------------------------------
;; Try-only acquisition

;; path-string string string (-> any) -> any
;; vault-root id note thunk [#:on-stale-holder]
;; (parameter names avoid the holder accessors holder-id/holder-note)
(define (call-with-vault-lock vault-root id note thunk
                              #:on-stale-holder [on-stale-holder #f])
  (define e (table-entry (vault-lock-path vault-root)))
  (unless (semaphore-try-wait? (entry-sema e))
    (raise-busy vault-root (unbox (entry-held e))))
  (dynamic-wind
    void
    (lambda ()
      (call-with-file-lock/timeout
       vault-root 'exclusive
       (lambda ()
         (define previous (read-owner-file vault-root))
         (when (and previous (not (equal? (holder-id previous) id)))
           (when on-stale-holder (on-stale-holder previous)))
         (set-box! (entry-held e)
                   (holder id note (current-seconds)))
         (write-owner-file vault-root id note)
         (thunk))
       (lambda ()
         (raise-busy vault-root (read-owner-file vault-root)))
       #:lock-file (path->string (vault-lock-path vault-root))
       #:max-delay 0))
    (lambda ()
      (set-box! (entry-held e) #f)
      (remove-owner-file vault-root)
      (semaphore-post (entry-sema e)))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/system
           "errors.rkt")

  (define test-root (make-temporary-directory "pm-lock~a"))
  (define vault-dir (build-path test-root "vault.git"))
  (make-directory vault-dir)

  ;; Free acquisition runs the thunk and releases (second take works).
  (check-equal? (call-with-vault-lock vault-dir "job-1" "add demo"
                                      (lambda () 'ran))
                'ran)
  (check-equal? (call-with-vault-lock vault-dir "job-2" "add demo"
                                      (lambda () 'ran-again))
                'ran-again)

  ;; Re-entrant attempt in the same process fails at once naming the holder.
  (define reentry-error
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (call-with-vault-lock vault-dir "outer" "outer op"
                            (lambda ()
                              (call-with-vault-lock vault-dir "inner" "inner op"
                                                    (lambda () 'never))))
      'no-error))
  (check-pred config-error? reentry-error)
  (check-regexp-match #rx"vault busy" (exn-message reentry-error))
  (check-regexp-match #rx"outer" (exn-message reentry-error))
  ;; The outer lock released cleanly despite the inner failure.
  (check-equal? (call-with-vault-lock vault-dir "after" "ok"
                                      (lambda () 'free-again))
                'free-again)

  ;; Two threads race: exactly one wins, the loser names the holder.
  ;; Attempts never block. A semaphore barrier (not the results channel)
  ;; forces overlap: the winner cannot release until the loser has
  ;; attempted, so no scheduling avoids the contention.
  (define race-results (make-channel))
  (define race-barrier (make-semaphore))
  (define (racer tag)
    (thread
     (lambda ()
       (define outcome
         (with-handlers ([exn:fail:pm?
                          (lambda (e) (list 'lost tag (exn-message e)))])
           (call-with-vault-lock vault-dir tag "race"
                                 (lambda ()
                                   (semaphore-wait race-barrier)
                                   (list 'won tag)))))
       (channel-put race-results outcome))))
  (void (racer "racer-a"))
  (void (racer "racer-b"))
  ;; The loser posts first (its attempt fails at once); the barrier
  ;; release below can only unblock the winner afterwards.
  (define first-report (channel-get race-results))
  (check-pred (lambda (r) (and (pair? r) (eq? (car r) 'lost))) first-report)
  (semaphore-post race-barrier)
  (define second-report (channel-get race-results))
  (check-pred (lambda (r) (and (pair? r) (eq? (car r) 'won))) second-report)
  ;; The loser names the winner as holder.
  (check-regexp-match #rx"vault busy" (caddr first-report))
  (check-true (regexp-match? (regexp (cadr second-report))
                             (caddr first-report)))

  ;; Cross-process contention fails at once; release and death both end
  ;; observably (no timers). The holder is a Racket child (only Racket
  ;; takes this lock: it is a .LOCK existence file, invisible to
  ;; flock/fcntl -- a kill -9 leaves it stale by design, and the owner
  ;; record names the dead holder).
  (define holder-path (build-path test-root "holder.rkt"))
  ;; Absolute path of this module, for the holder child's require: derived
  ;; from the load directory so the suite runs from anywhere.
  (define this-mod
    (path->string
     (simplify-path
      (build-path (or (current-load-relative-directory) (current-directory))
                  "vault-lock.rkt"))))
  (define up-path (build-path test-root "up.fifo"))
  (define block-path (build-path test-root "block.fifo"))
  (define die-path (build-path test-root "die.fifo"))
  (define mkfifo-exe (find-executable-path "mkfifo"))
  (define racket-exe (find-system-path (quote exec-file)))
  (check-pred path-string? mkfifo-exe)
  (check-pred path-string? racket-exe)
  (define (make-fifo! path)
    (define maker (process* (path->string mkfifo-exe) (path->string path)))
    ((list-ref maker 4) 'wait)
    (check-true (file-exists? path)))
  (make-fifo! up-path)
  (make-fifo! block-path)
  (make-fifo! die-path)
  ;; The holder acquires, signals up, holds die-write open, blocks on
  ;; block-read. Every barrier below is a FIFO read or EOF.
  (call-with-output-file holder-path
    (lambda (port)
      (displayln "#lang racket/base" port)
      (displayln "(require racket/file" port)
      (displayln (format "         (file ~s)" this-mod) port)
      (displayln "         racket/system)" port)
      (displayln (format "(define vault-dir ~s)" (path->string vault-dir)) port)
      (displayln (format "(define up-path ~s)" (path->string up-path)) port)
      (displayln (format "(define block-path ~s)" (path->string block-path)) port)
      (displayln (format "(define die-path ~s)" (path->string die-path)) port)
      (displayln "(call-with-vault-lock vault-dir \"rkt-holder\" \"add demo\"" port)
      (displayln "  (lambda ()" port)
      (displayln "    (define-values (die-in die)" port)
      (displayln "      (open-input-output-file die-path #:exists (quote update)))" port)
      (displayln "    (close-input-port die-in)" port)
      (displayln "    ;; ONE write end held for the whole handshake:" port)
      (displayln "    ;; with zero writers a Racket fifo read returns EOF" port)
      (displayln "    ;; at once, so the writer must outlive every read." port)
      (displayln "    (define up-hold (open-output-file up-path #:exists (quote update)))" port)
      (displayln "    (displayln \"up\" up-hold) (flush-output up-hold)" port)
      (displayln "    (define in (open-input-file block-path))" port)
      (displayln "    (read-line in) (close-input-port in)" port)
      (displayln "    (displayln \"bye\" up-hold) (flush-output up-hold)" port)
      (displayln "    (close-output-port up-hold)" port)
      (displayln "    (close-output-port die)))" port)))
  (define holder-proc
    (process* (path->string racket-exe) (path->string holder-path)))
  (define holder-ctl (list-ref holder-proc 4))
  ;; Rendezvous discipline (D-015): every fifo keeps a writer held open
  ;; continuously from before the first open until after the last read. A
  ;; transient writer that opens+writes+closes before a slow reader opens
  ;; strands the reader in open() (or hands it early EOF), so write ends
  ;; must outlive the whole handshake on both directions.
  (define block-out (open-output-file block-path #:exists 'update))
  (define up-held
    (open-output-file up-path #:exists 'update))
  (define up-in (open-input-file up-path))
  ;; The up line arrives only after the child holds the lock.
  (check-equal? (read-line up-in) "up")
  ;; Contender fails at once, naming the live holder.
  (define held-error
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (call-with-vault-lock vault-dir "contender" "add demo" (lambda () 'never))
      'no-error))
  (check-pred config-error? held-error)
  (check-regexp-match #rx"vault busy" (exn-message held-error))
  (check-regexp-match #rx"rkt-holder" (exn-message held-error))
  ;; Release via the block fifo; bye proves release preceded it, so the
  ;; retry below cannot race the child's shutdown.
  (displayln "go" block-out)
  (flush-output block-out)
  (check-equal? (read-line up-in) "bye")
  (close-output-port block-out)
  (close-output-port up-held)
  (close-input-port up-in)
  (check-equal? (call-with-vault-lock vault-dir "after-child" "ok"
                                      (lambda () 'free))
                'free)
  ;; Death self-heals the Racket lock but leaves the owner record stale:
  ;; kill a fresh holder, observe death by EOF, then a new acquisition
  ;; SUCCEEDS while the stale callback names the dead holder.
  ;; Parent-held write end again: holder2 boots Racket (slow, so the
  ;; parent usually opens first, but the hold makes it certain).
  (define up-held2
    (open-output-file up-path #:exists 'update))
  (define holder2
    (process* (path->string racket-exe) (path->string holder-path)))
  (define up2-in (open-input-file up-path))
  (check-equal? (read-line up2-in) "up")
  (close-input-port up2-in)
  (close-output-port up-held2)
  (define died-reports (make-channel))
  (void
   (thread (lambda ()
             (define in (open-input-file die-path))
            (define v (read in))
            (close-input-port in)
            (channel-put died-reports v))))
  (define killer
    (process* "/usr/bin/sh" "-c"
              (format "kill -9 ~a" (number->string (list-ref holder2 2)))))
  ((list-ref killer 4) 'wait)
  (check-pred eof-object? (channel-get died-reports))
  (define stale-seen (box #f))
  (check-equal? (call-with-vault-lock vault-dir "after-death" "add demo"
                                      (lambda () 'recovered)
                                      #:on-stale-holder
                                      (lambda (prev)
                                        (set-box! stale-seen (holder-id prev))))
                'recovered)
  (check-equal? (unbox stale-seen) "rkt-holder")
  (holder-ctl 'wait)
  ((list-ref holder2 4) 'wait)

  (delete-directory/files test-root))
