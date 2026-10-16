#lang racket/base
;; build-systems/cargo.rkt -- the cargo word: cargo with the step's
;; flags in the step dir. It builds the command only; build-executor.rkt
;; spawns it.

(require "../build-env.rkt")

(provide
 ;; (listof any) path path -> (values string (listof string) path)
 cargo-command)

;; (listof any) path path -> (values string (listof string) path)
(define (cargo-command args work source)
  (define dir (resolve-dir 'cargo (as-string (arg-val args '#:dir ".")
                                             ".")
                           work source))
  (define flags (as-strings (arg-val args '#:args '())))
  (values "cargo" flags dir))
