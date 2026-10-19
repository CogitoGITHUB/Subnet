#lang racket/base
;; One job: the error record — what happened, who, where.
;; The floor of the package: this file uses nothing from any other area.
;; Lands with TODO item 1 (the tree lands).
;;
;; This build has no gen:custom-write ("bad require spec" — found by the first
;; by-hand run, 2026-10-17), so the record carries no writer of its own.
;; Printing is render.rkt's one job, and that is where the shape lives.

(struct exn:notation exn:fail (who where)
  #:transparent)

;; make-err builds the record; it never raises, so a caller may hold an error
;; as a value and decide later whether to raise or to report it.
;;
;; exn:notation inherits from exn:fail, and exn:fail inherits from exn, whose
;; fields are the message and the continuation marks. The constructor therefore
;; takes four arguments, not three: the message, the marks, the area and the
;; place. Passing the marks is what makes the raise carry where it came from.
(define (make-err who where what)
  ;; who   — the area or the stage that hit the problem, in words
  ;; where — the file and line, or the command, in words
  ;; what  — what went wrong, one sentence, no dump
  (exn:notation (format "~a" what) (current-continuation-marks) who where))

;; err-who / err-where / err-what read the three fields without touching the
;; message string; every reader in the package goes through these.
(define (err-who e)   (exn:notation-who e))
(define (err-where e) (exn:notation-where e))
(define (err-what e)  (exn-message e))

(provide make-err err-who err-where err-what (struct-out exn:notation))
