#lang racket/base
;; One job: a run's voice — open, step, note, warn, skip, decide.
;; Registered in plan/package-tree.org; lands with TODO item 1.
;;
;; These are the six ways a run speaks. Each one builds an event and hands it
;; to the one printer, so every line a run says has the same shape and the
;; same fields: who and why (rule 05), and the UTC time of the moment
;; (rule 06).

(require "events.rkt"
         "print-console.rkt")

;; open-run starts a run: who is running, and why this run happens.
(define (open-run who why) (say 'ev-open who why))

;; step reports one step of the work.
(define (step who why) (say 'ev-step who why))

;; note records something worth keeping.
(define (note who why) (say 'ev-note who why))

;; warn says what is wrong, and the run goes on.
(define (warn who why) (say 'ev-warn who why))

;; skip says what was not done, and why it was not done.
(define (skip who why) (say 'ev-skip who why))

;; decide says what was chosen, and why.
(define (decide who why) (say 'ev-decide who why))

;; say builds one event with the voice's clock and hands it to the one
;; printer. It is the only place an event is made.
(define (say kind who why)
  (print-event (make-event kind who why (utc-now) #f #f #f #f)))

;; The six voices, for every area above this one.
(provide open-run
         step
         note
         warn
         skip
         decide)
