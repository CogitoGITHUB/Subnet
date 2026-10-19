#lang racket/base
;; One job: the event record — schema only, decides nothing.
;; Lands with TODO item 1 (the floor). Narration uses the errors floor and
;; nothing above it.

;; An event is one thing that happened: its kind, what it was, and the
;; detail a reader may want.
(struct ev (kind what detail)
  #:transparent)

;; The six kinds a run's voice may speak (plan/architecture.org, narration).
;; A seventh kind is not added here: the record carries the schema, the owner
;; decides the vocabulary.
(define ev-kinds '(open step note warn skip decide))

;; ev-kind-of? says whether an event is of one kind, so a caller can pick
;; the events it cares about.
(define (ev-kind-of? kind)
  (and (memq kind ev-kinds) #t))

;; make-ev builds one event. what is a short sentence. detail is always given
;; explicitly, as #f when there is nothing more to say: this Racket build
;; counts an optional bracket parameter as required and answers "arity
;; mismatch; expected 4, given 3" when it is left out (found by the first
;; by-hand run, 2026-10-17).
(define (make-ev kind what detail)
  (ev kind what detail))

;; ev-line renders an event as one terminal line. Rendering text is the
;; printer's job; this only gives it the fields.
(define (ev-line e)
  (define kind (ev-kind e))
  (define what (ev-what e))
  (define detail (ev-detail e))
  (if detail
      (format "~a: ~a — ~a" kind what detail)
      (format "~a: ~a" kind what)))

(provide make-ev ev-line ev-kinds (struct-out ev))
