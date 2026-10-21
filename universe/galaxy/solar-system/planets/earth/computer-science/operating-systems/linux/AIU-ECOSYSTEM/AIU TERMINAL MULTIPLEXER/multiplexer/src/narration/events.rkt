#lang racket/base
;; One job: the event record — schema only, decides nothing.
;; Registered in plan/package-tree.org. The field list is lifted verbatim from
;; agents/narration.md, so feeds from different tools stay mutually readable.
;; Nothing here stamps, numbers, checks or prints: narration.rkt does that, and
;; this file only says what an event is.
;;
;; kind is closed: START STEP INFO DECIDE SKIP PROGRESS END FAIL WARN, plus the
;; wait door's WAIT and WAIT-DONE (agents/verbosity.md).

;; provide is the schema: the record, the closed kinds and the field order.
(provide (struct-out event)
         event-kinds
         event-kind?
         event-fields)

;; event is the one record of what happened, in the schema's order.
(struct event (run-id seq parent-id kind depth who what why how
                    inputs outputs result utc mono-ms duration-ms)
  #:transparent)

;; event-kinds is the closed set of kinds: a kind outside it is a caller's bug,
;; and event-kind? says so without deciding anything else.
(define event-kinds
  '(START STEP INFO DECIDE SKIP PROGRESS END FAIL WARN WAIT WAIT-DONE))

;; event-kind? answers whether a value is one of the closed kinds.
(define (event-kind? k)
  (if (memq k event-kinds) #t #f))

;; event-fields names the schema's fields in the schema's order, for the reader
;; that writes the record as JSON Lines later; the order is never local taste.
(define event-fields
  '(run-id seq parent-id kind depth who what why how
    inputs outputs result utc mono-ms duration-ms))
