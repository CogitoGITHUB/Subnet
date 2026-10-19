#lang racket/base
;; One job: how an error prints — one shape, never a dump.
;; Registered in plan/package-tree.org; lands with TODO item 1.
;;
;; An error is one line. It never prints a struct, never prints a stack and
;; never prints more than the five fields the record holds.
;;
;; This file is in the errors area, the floor of the program, so it cannot
;; require the printer above it: the printer, in the narration area, prints
;; what this file builds. The line is made here and shown there.

(require "err.rkt")

;; err-line returns the one line an error prints as. The order never changes:
;; who, where, kind, what, and what to do.
(define (err-line e)
  (format "ERR ~a at ~a: ~a: ~a; what to do: ~a"
          (err-who e) (err-where e) (err-kind e) (err-what e) (err-what-to-do e)))

;; The one line an error prints as, for every area above this one.
(provide err-line)
