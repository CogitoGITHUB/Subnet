#lang racket/base
;; One job: a run's voice — open, step, note, warn, skip, decide.
;; Lands with TODO item 1 (the floor). This file only makes events and hands
;; them to the printer; it never decides what a run should say next.

(require "events.rkt"
         "print-console.rkt")

(provide say-open say-step say-note say-warn say-skip say-decide)


;; say-open names the run and what it was asked to do.
(define (say-open what detail)
  (print-ev (make-ev 'open what detail)))

;; say-step names the stage and what it is doing right now.
(define (say-step what detail)
  (print-ev (make-ev 'step what detail)))

;; say-note carries an ordinary fact, with no judgement in it.
(define (say-note what detail)
  (print-ev (make-ev 'note what detail)))

;; say-warn says something is off but the run continues.
(define (say-warn what detail)
  (print-ev (make-ev 'warn what detail)))

;; say-skip says work was not done and names why, so a skip never looks like
;; a pass. Nothing in the package may skip work without saying so here.
(define (say-skip what why)
  (print-ev (make-ev 'skip what why)))

;; say-decide names a choice that was made, and the reason for it.
(define (say-decide what why)
  (print-ev (make-ev 'decide what why)))