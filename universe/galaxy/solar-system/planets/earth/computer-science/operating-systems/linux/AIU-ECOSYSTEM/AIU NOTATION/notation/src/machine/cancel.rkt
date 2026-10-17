#lang racket/base
;; One job: the cancellation door every blocking call passes.
;; Lands with TODO item 1 (the floor). A blocking call takes this door and
;; checks it; nothing else may decide on its own that it should stop.

(require "../errors/raise.rkt")

;; A door is one mutable fact: cancelled, or not. It carries no reason and no
;; history; the reason belongs to whoever pressed the door, and the run that
;; was waiting says why it stopped.
(struct door (flag) #:transparent)

(define (make-cancel-door)
  (door (box #f)))

(define (cancel! d)
  (set-box! (door-flag d) #t))

(define (cancelled? d)
  (unbox (door-flag d)))

;; check-cancel raises when the door is closed. A blocking call calls it before
;; it starts and again the moment it comes back, so a cancelled run stops at
;; the next safe point instead of finishing the work it no longer wants.
(define (check-cancel d who)
  (when (cancelled? d)
    (raise-err 'cancel "cancel.rkt" (format "cancelled before ~a" who))))

;; guard-cancel runs a blocking call under one door: it checks the door before
;; the call, makes the call, checks again, and returns whatever the call
;; returned. It never swallows an error — one raised by the call travels out
;; unchanged.
(define (guard-cancel d who thunk)
  (check-cancel d who)
  (define result (thunk))
  (check-cancel d who)
  result)