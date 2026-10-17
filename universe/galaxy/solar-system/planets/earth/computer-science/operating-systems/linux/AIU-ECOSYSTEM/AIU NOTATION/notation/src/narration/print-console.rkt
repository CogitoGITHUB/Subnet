#lang racket/base
;; One job: the ONE printer to the terminal.
;; Lands with TODO item 1 (the floor). Nothing else writes to the terminal.

(require "events.rkt")

;; print-ev writes one event as one line, then flushes, so a run that is
;; cancelled still shows what it said last.
(define (print-ev e)
  (printf "~a\n" (ev-line e))
  (flush-output (current-output-port)))

;; print-line writes one already-formed line. Kept for stages that have a
;; line to show and no event to wrap it in.
(define (print-line line)
  (printf "~a\n" line)
  (flush-output (current-output-port)))

;; print-nothing is a named no-op: a stage that would otherwise print an empty
;; result says so instead of staying silent.
(define (print-nothing what)
  (print-line (format "NOTHING-TO-CHECK ~a" what)))