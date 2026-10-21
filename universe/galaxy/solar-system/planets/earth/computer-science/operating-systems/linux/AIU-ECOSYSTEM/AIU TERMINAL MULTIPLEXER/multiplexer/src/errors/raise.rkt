#lang racket/base
;; One job: the one raise helper; nothing raises around it.
;; Registered in plan/package-tree.org. Every failure in the package becomes an
;; mp-error and leaves through raise-error: one door, one shape, one place to
;; find every failure. No other file calls error, raise or raise-user-error.
(require "err.rkt")

;; provide is the one door: everything that fails calls raise-error.
(provide raise-error)

;; checked-field answers a field that must carry something, and refuses a blank
;; or missing one. That refusal is a plain error here on purpose: this file is
;; the one raiser, so a malformed record is caught where records are made.
(define (checked-field name v)
  (if (and (string? v) (not (blank-string? v)))
      v
      (error 'raise-error "an mp-error field is blank: ~a" name)))

;; raise-error raises one mp-error: what, who, where and why are required;
;; rule and detail are not. A blank required field is refused before the record
;; exists, so an incomplete error can never reach a reader.
(define (raise-error what who where why
                     #:rule [rule #f]
                     #:detail [detail #f])
  (raise (mp-error (checked-field 'what what)
                   (checked-field 'who who)
                   (checked-field 'where where)
                   (checked-field 'why why)
                   rule
                   detail)))
