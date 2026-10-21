#lang racket/base
;; One job: the cancellation door every blocking call passes.
;; Registered in plan/package-tree.org. A cancellation is asked once, with a
;; reason, and is never cleared: the state is shared, and every blocking call
;; passes check-cancel! before it blocks and after it returns, so a cancel ends
;; the wait instead of being noticed after it (agents/verbosity.md, rule 3).
(require "../errors/err.rkt"
         "../errors/raise.rkt")

;; provide is the door: the state, the ask, the reading and the two checks.
(provide (struct-out cancel-state)
         make-cancel
         cancel!
         cancelled?
         cancel-why
         check-cancel!
         cancellable)

;; cancel-state is the shared flag and its reason: set once, read everywhere.
(struct cancel-state (flag why) #:mutable)

;; make-cancel answers a state nobody has cancelled.
(define (make-cancel)
  (cancel-state #f #f))

;; cancel! marks the state cancelled and records why. A blank reason is refused:
;; a cancellation nobody can explain is a bug in the caller.
(define (cancel! c why)
  (when (blank-string? why)
    (raise-error "a cancellation reason was blank"
                 "machine/cancel cancel!"
                 "the cancel state"
                 "no reason was given; someone must be able to say why work stopped"
                 #:rule 'cancel/why-mandatory))
  (set-cancel-state-flag! c #t)
  (set-cancel-state-why! c why))

;; cancelled? answers whether a cancellation was asked for.
(define (cancelled? c)
  (cancel-state-flag c))

;; cancel-why answers the recorded reason, or #f when nothing was cancelled.
(define (cancel-why c)
  (cancel-state-why c))

;; check-cancel! is the door: every blocking call passes it. A cancelled state
;; raises one mp-error naming where the block was, so nothing waits on.
(define (check-cancel! c where)
  (when (cancelled? c)
    (raise-error "the work was cancelled"
                 "machine/cancel check-cancel!"
                 where
                 (cancel-why c)
                 #:rule 'cancel/cancelled)))

;; cancellable runs one blocking thunk between two passes of the door: before it
;; blocks and after it returns. Only the thunk runs between the passes, so no
;; second blocking call hides inside.
(define (cancellable c where thunk)
  (check-cancel! c where)
  (define v (thunk))
  (check-cancel! c where)
  v)
