#lang racket/base
;; One job: the error record — what happened, who, where.
;; The floor of the package: this file uses nothing from any other area.
;; Lands with TODO item 1 (the tree lands).

(struct exn:notation exn:fail (who where)
  #:transparent
  #:methods gen:custom-write
  [(write-exn e port _)
   (fprintf port "ERR ~a at ~a: ~a" (exn:notation-who e) (exn:notation-where e)
            (exn-message e))])

;; make-err builds the record; it never raises, so a caller may hold an error
;; as a value and decide later whether to raise or to report it.
(define (make-err who where what)
  ;; who   — the area or the stage that hit the problem, in words
  ;; where — the file and line, or the command, in words
  ;; what  — what went wrong, one sentence, no dump
  (exn:notation (format "~a" what) who where))

;; err-who / err-where / err-what read the three fields without touching the
;; message string; every reader in the package goes through these.
(define (err-who e)   (exn:notation-who e))
(define (err-where e) (exn:notation-where e))
(define (err-what e)  (exn-message e))