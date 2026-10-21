#lang racket/base
;; One job: the ONE printer to the terminal.
;; Registered in plan/package-tree.org. Every line the program shows a person
;; leaves through print-event or print-line; no other file calls display,
;; displayln or printf for the screen. The port may be redirected by a caller;
;; nothing here silences it.
(require "events.rkt")

;; provide is the two printers: an event's line and a finished line of text.
(provide print-event
         print-line)

;; indent-for answers the two-space indent of a nesting depth, so a nested
;; event reads as nested.
(define (indent-for depth)
  (if (and (integer? depth) (> depth 0))
      (make-string (* 2 depth) #\space)
      ""))

;; has-value? answers whether a field is worth printing: #f is not, and neither
;; is an empty string. A label with nothing under it is noise on the screen.
(define (has-value? v)
  (and v (not (equal? v ""))))

;; field-part answers " | name: value" for a field that has a value, and ""
;; when it has not.
(define (field-part label v)
  (if (has-value? v) (format " | ~a: ~a" label v) ""))

;; event-line answers the screen shape of one event:
;; "[HH:MM:SSZ +0.250s] KIND who | what: ... | why: ... | how: ...".
(define (event-line e)
  (format "~a[~a +~as] ~a ~a | what: ~a~a~a"
          (indent-for (event-depth e))
          (event-utc e)
          (real->decimal-string (/ (event-mono-ms e) 1000.0) 3)
          (event-kind e)
          (event-who e)
          (event-what e)
          (field-part "why" (event-why e))
          (field-part "how" (event-how e))))

;; print-event prints one event's line and flushes it, so a killed process
;; leaves a readable prefix and never a torn record.
(define (print-event e)
  (displayln (event-line e))
  (flush-output))

;; print-line prints one finished line — a rendered error, a refusal, a note
;; from outside the run — and flushes it. Text shaped elsewhere comes here
;; rather than to a second printer.
(define (print-line s)
  (displayln s)
  (flush-output))
