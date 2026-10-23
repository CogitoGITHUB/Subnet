#lang racket/base
;; One job: how an error prints — one shape, never a dump.
;; Registered in plan/package-tree.org. render-error answers the one line every
;; failure prints, whatever area it came from. The machine detail stays in the
;; log and never reaches the screen line: a dump is not a report.
(require "err.rkt")

;; provide is the one renderer: every area prints a failure through this shape.
(provide render-error)

;; rule-part answers " | rule: X" when a rule demanded the refusal, and "" when
;; none did, so the shape holds with and without a rule.
(define (rule-part rule)
  (if rule (format " | rule: ~a" rule) ""))

;; render-error answers one line:
;; "ERROR what | who: ... | where: ... | why: ... [| rule: ...]".
(define (render-error e)
  (format "ERROR ~a | who: ~a | where: ~a | why: ~a~a"
          (mp-error-what e)
          (mp-error-who e)
          (mp-error-where e)
          (mp-error-why e)
          (rule-part (mp-error-rule e))))
