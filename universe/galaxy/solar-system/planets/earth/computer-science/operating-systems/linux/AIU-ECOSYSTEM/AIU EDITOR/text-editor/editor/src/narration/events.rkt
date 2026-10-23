#lang racket/base
;; One job: the event record — the schema, and the clock that fills it.
;; Registered in plan/package-tree.org; lands with TODO item 1.
;;
;; An event is what a run says happened. It carries who and why (rule 05), the
;; UTC start and end and the monotonic duration (rule 06), and a data field
;; that holds the shape the writer chose. The record decides nothing: it does
;; not print, it does not judge and it does not act.

(require racket/date
         racket/string
         "../errors/raise.rkt")

;; event is the one record of this program. Its fields, in order:
;;   kind        what happened, a symbol: ev-open, ev-step, ev-note, ev-warn,
;;               ev-skip, ev-decide, ev-wait, ev-wait-done
;;   who         who did it: a person, a program (opencode, hermes) or a file
;;   why         why it happened, at intent level; never blank
;;   started     the UTC start, as an ISO-8601 string
;;   ended       the UTC end, as an ISO-8601 string, or #f while it runs
;;   duration-ms the monotonic duration in milliseconds, or #f while it runs
;;   data        the writer's own shape: a list of pairs, a list of values, a
;;               string, a number, or #f
;;   redacted    whether something in the data was hidden, so a reader sees
;;               that a redaction happened instead of missing it
(struct event (kind who why started ended duration-ms data redacted) #:transparent)

;; make-event builds an event and refuses a blank why: an event with no
;; reason cannot be explained later, so it is never made.
(define (make-event kind who why started ended duration-ms data redacted)
  (if (or (not (string? why)) (string=? (string-trim why) ""))
      (error-of 'err-blank-why who "the event record"
                "an event was made with no reason"
                "say why the event happened, at intent level")
      (event kind who why started ended duration-ms data redacted)))

;; utc-now answers the current UTC time as an ISO-8601 string. The clock only
;; reads time; it decides nothing.
(define (utc-now)
  (define d (seconds->date (current-seconds) #t))
  (format "~a-~a-~aT~a:~a:~aZ"
          (date-year d) (two-digits (date-month d)) (two-digits (date-day d))
          (two-digits (date-hour d)) (two-digits (date-minute d)) (two-digits (date-second d))))

;; two-digits pads a number to two digits, so a timestamp sorts as text.
(define (two-digits n)
  (if (< n 10) (format "0~a" n) (format "~a" n)))

;; monotonic-ms answers the milliseconds since the process started, read on a
;; monotonic clock, so a duration is never wrong because the clock moved.
(define (monotonic-ms)
  (inexact->exact (round (current-inexact-milliseconds))))

;; The record and the clock, for every area above this one.
(provide event
         make-event
         utc-now
         monotonic-ms
         event-kind
         event-who
         event-why
         event-started
         event-ended
         event-duration-ms
         event-data
         event-redacted)
