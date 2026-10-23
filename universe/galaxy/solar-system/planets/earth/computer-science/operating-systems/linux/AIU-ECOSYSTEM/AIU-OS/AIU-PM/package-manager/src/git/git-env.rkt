#lang racket/base
;; git-url.rkt -- git URL validation (pure). Called at spec-read time
;; (file:line:col errors) AND again at the backend boundary (S-1).

(require racket/contract/base
         racket/string
         racket/list
         "../errors/error-type.rkt"
         "../security/security.rkt")

(provide
  (contract-out
   ;; Tests may enable file:// URLs; production never does (default #f).
   [current-allow-file-urls (parameter/c boolean?)]))
