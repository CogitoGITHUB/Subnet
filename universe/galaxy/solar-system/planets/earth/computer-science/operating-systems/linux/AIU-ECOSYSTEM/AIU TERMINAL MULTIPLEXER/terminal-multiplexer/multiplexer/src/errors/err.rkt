#lang racket/base
;; One job: the error record — what happened, who, where.
;; Registered in plan/package-tree.org. errors is the floor of the area table:
;; this file requires nothing, so every other area may require it.
;;
;; The record answers the questions a failure must answer, and nothing more:
;;   what   — what went wrong, in one sentence a reader can act on
;;   who    — the area and the function that decided
;;   where  — the file, command, pane or path the failure is about
;;   why    — the reason it was refused or failed; never blank
;;   rule   — the rule or decision that demanded the refusal, or #f
;;   detail — machine detail for a log; never printed on the screen line
;;
;; Deciding is not this file's job and neither is raising: it holds the shape.
;; raise.rkt raises it; render.rkt prints it. Nothing here calls error or
;; raise, so the one raise helper stays the one raiser.

;; blank-string? answers whether a value is a string of nothing but whitespace,
;; which is how every required field is tested. A missing value is not blank:
;; it is a different fault, and callers tell the two apart.
(define (blank-string? s)
  (and (string? s)
       (for/and ([c (in-string s)]) (char-whitespace? c))))

;; provide is what other areas may use: the record and its accessors, and the
;; blank test every area shares. Nothing else leaves this file.
(provide (struct-out mp-error)
         blank-string?)

;; mp-error is the one error record of the program: the four questions, the
;; rule that demanded the refusal (#f when none did) and the machine detail.
;; It is deliberately not an exn: it is a record that the one raise helper
;; raises, and a caller that catches must catch any value, not only exn:fail.
(struct mp-error (what who where why rule detail) #:transparent)

;; error-complete? answers whether a record carries what the law requires:
;; what, who, where and why, each a string with something in it. It is total:
;; it refuses nothing and raises nothing.
(define (error-complete? e)
  (and (string? (mp-error-what e)) (not (blank-string? (mp-error-what e)))
       (string? (mp-error-who e)) (not (blank-string? (mp-error-who e)))
       (string? (mp-error-where e)) (not (blank-string? (mp-error-where e)))
       (string? (mp-error-why e)) (not (blank-string? (mp-error-why e)))))
