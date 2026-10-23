#lang racket/base
;; package-name.rkt -- package name validation (D-8). Pure, no I/O.

(require racket/contract/base
         racket/regexp
         "../errors/error-type.rkt")

(provide
  (contract-out
   ;; any -> boolean, symbol matching D-8 names
   [package-name? (-> any/c boolean?)]))

;; ---------------------------------------------------------------------------
;; Names (D-8)

;; any -> boolean, [a-z0-9][a-z0-9-]* as a symbol
(define (package-name? v)
  (and (symbol? v)
       (regexp-match? #rx"^[a-z0-9][a-z0-9-]*$"
                       (symbol->string v))))