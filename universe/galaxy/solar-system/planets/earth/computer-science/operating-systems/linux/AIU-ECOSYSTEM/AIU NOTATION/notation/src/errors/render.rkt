#lang racket/base
;; One job: how an error prints — one shape, never a dump.
;; Lands with TODO item 1 (the tree lands).

(require racket/string
         "err.rkt")

;; render-err returns the one line an error is allowed to become:
;;   ERR <who> at <where>: <what>
(define (render-err e)
  (format "ERR ~a at ~a: ~a" (err-who e) (err-where e) (err-what e)))

;; render-err-list renders many errors, one per line, in the order given, so a
;; stage that collects problems prints them the same way every time.
(define (render-err-list es)
  (string-join (map render-err es) "\n"))