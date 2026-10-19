#lang racket/base
;; One job: the cancellation door — every blocking call passes it.
;; Registered in plan/package-tree.org; lands with TODO item 1.
;;
;; A blocking call that cannot be stopped is a call that can outlive the
;; reason it was made. So every blocking call takes a door: it checks the
;; door before it starts and after it waits, and says so when it was
;; cancelled. Closing the door is an event, so a wait ends on the door and
;; not on a timer (rule 04).

(require "../errors/raise.rkt")

;; cancel-token is the door: a flag that says whether it is closed, and a
;; signal that wakes whoever waits on it.
(struct cancel-token (closed? signal) #:transparent)

;; new-cancel-token makes a door that is open.
(define (new-cancel-token)
  (cancel-token #f (make-semaphore)))

;; cancelled? answers whether the door is closed.
(define (cancelled? t)
  (cancel-token-closed? t))

;; cancel closes the door and wakes every waiter on it, so a wait ends on the
;; event "the door closed" and not on a clock.
(define (cancel t)
  (unless (cancelled? t)
    (set-cancel-token-closed?! t #t)
    (semaphore-post (cancel-token-signal t))))

;; check-cancel refuses when the door is closed, so a cancelled call never
;; goes on to act.
(define (check-cancel t who what)
  (when (cancelled? t)
    (error-of 'err-cancelled who what
              "the call was cancelled before it acted"
              "the caller stopped waiting for this work")))

;; await-cancel blocks until the door is closed. It ends on that event only.
(define (await-cancel t)
  (sync (cancel-token-signal t)))
