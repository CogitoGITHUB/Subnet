#lang racket/base
;; One job: how an error prints — one shape, never a dump.
;; Lands with TODO item 1 (the tree lands).

(require racket/string
         "err.rkt")

;; This build has no gen:custom-write ("bad require spec", 2026-10-17), so
;; this file is also the only way an error becomes text: the two bindings are
;; provided so diagnostics/report.rkt renders a finding through them instead
;; of printing a second shape of its own. (Added with TODO item 5.)
(provide render-err render-err-list)

;; render-err returns the one line an error is allowed to become:
;;   ERR <who> at <where>: <what>
(define (render-err e)
  (format "ERR ~a at ~a: ~a" (err-who e) (err-where e) (err-what e)))

;; render-err-list renders many errors, one per line, in the order given, so a
;; stage that collects problems prints them the same way every time.
(define (render-err-list es)
  (string-join (map render-err es) "\n"))