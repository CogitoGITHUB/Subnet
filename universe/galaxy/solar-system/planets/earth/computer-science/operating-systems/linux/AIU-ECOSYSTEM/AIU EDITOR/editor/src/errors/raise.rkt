#lang racket/base
;; One job: the one raise helper — nothing raises around it.
;; Registered in plan/package-tree.org; lands with TODO item 1.
;;
;; Every error in this program leaves through this one function. No other file
;; calls raise, so there is exactly one place where an error becomes an
;; exception, and one place to look when an error does not arrive.

(require "err.rkt")

;; raise-error is the one way an error leaves this program. It takes the error
;; record and raises it, keeping the record whole inside the exception.
(define (raise-error e)
  (raise (exn:fail:editor (err-what e) (current-continuation-marks) e)))

;; error-of builds an error record and raises it in one call, for the common
;; case where the caller holds all five fields in hand.
(define (error-of kind who where what what-to-do)
  (raise-error (err kind who where what what-to-do)))

;; The one way out of this program, for every area above it.
(provide raise-error
         error-of)
