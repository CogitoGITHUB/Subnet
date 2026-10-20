#lang racket/base
;; One job: the wait door — wait-for and wait-done, and a why that is never blank.
;; Registered in plan/package-tree.org; lands with TODO item 1.
;;
;; Rule 04: every wait ends on an event, and nothing polls. So the door does
;; not wait here: it announces the wait, says what ends it, and the caller
;; waits on that event. A wait with no reason is refused, because a wait that
;; nobody can explain is a wait that never ends.

(require racket/string
         "events.rkt"
         "narration.rkt"
         "../errors/raise.rkt")

;; wait-for announces a wait: what is waited for, why, and the event that ends
;; it. The why and the event must both be there.
(define (wait-for who what why on-event)
  (if (or (blank? why) (blank? on-event))
      (error-of 'err-blank-why who "the wait door"
                "a wait was announced without a reason, or without the event that ends it"
                "say why the wait happens and name the event that ends it")
      (say 'ev-wait who (format "waiting for ~a: ~a; it ends on ~a" what why on-event))))

;; wait-done announces that a wait ended, and on which event.
(define (wait-done who what on-event)
  (say 'ev-wait-done who (format "the wait for ~a ended on ~a" what on-event)))

;; blank? answers whether a piece of text is missing or holds only spaces.
(define (blank? s)
  (or (not (string? s)) (string=? (string-trim s) "")))

;; The wait door, for every area above it.
(provide wait-for
         wait-done)
