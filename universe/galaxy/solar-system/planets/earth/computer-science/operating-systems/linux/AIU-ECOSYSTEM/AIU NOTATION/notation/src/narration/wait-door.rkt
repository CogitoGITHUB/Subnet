#lang racket/base
;; One job: wait-for / wait-done; why is never blank.
;; Lands with TODO item 1 (the floor). Every blocking call in the package
;; announces itself here before it blocks and again when it is through.

(require "events.rkt"
         "print-console.rkt"
         "../errors/raise.rkt")

(provide wait-for wait-done with-wait)


;; why-blank? is the whole point of this file: a wait without a reason is a
;; silence, and a silence is the failure this door exists to prevent.
(define (why-blank? why)
  (or (not (string? why))
      (null? (string->list why))
      (andmap char-whitespace? (string->list why))))

;; wait-for says what is about to block and why. why must not be blank; a
;; blank why is a programming error, not a run condition.
(define (wait-for what why)
  (when (why-blank? why)
    (raise-err 'wait-door "wait-door.rkt"
               (format "wait-for was given a blank why for ~a" what)))
  (print-ev (make-ev 'note (format "waiting: ~a" what) why)))

;; wait-done says the wait is over, naming how long it took in words and
;; never in numbers the reader must trust.
(define (wait-done what how)
  (print-ev (make-ev 'note (format "done waiting: ~a" what) how)))

;; with-wait is the shape every blocking call uses: say why, do the work, say
;; it is done. It does not swallow errors; they pass through untouched.
(define (with-wait what why thunk)
  (wait-for what why)
  (define result (thunk))
  (wait-done what "released")
  result)