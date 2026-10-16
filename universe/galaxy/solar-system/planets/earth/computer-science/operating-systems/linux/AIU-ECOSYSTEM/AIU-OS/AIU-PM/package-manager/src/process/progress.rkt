#lang racket/base
;; progress.rkt -- how much of a child's output a run KEEPS: the
;; captured-line bound and the tail it leaves. It must not read a pipe,
;; spawn anything, or decide an outcome.

(require racket/list)

(provide
 ;; Lines of tail output kept per stream; default 20.
 current-captured-lines
 ;; (listof string?) exact-nonnegative-integer? -> (listof string?)
 bounded-tail)

;; Lines of tail output kept per stream; default 20.
(define current-captured-lines (make-parameter 20))

;; NEWEST-FIRST list -> the newest LIMIT lines, still newest-first.
;;
;; Both collectors grow the same way (cons onto the front) and trim with
;; this one rule, so a long run keeps its END and drops its BEGIN. The
;; order is unchanged when the bound is not exceeded: the caller's own
;; reversal is the only place order is decided.
(define (bounded-tail newest-first limit)
  (if (> (length newest-first) limit)
      (reverse (cdr (reverse newest-first)))
      newest-first))
