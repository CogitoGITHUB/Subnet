#lang racket/base
;; git-id.rkt -- commit id validation (40/64 lowercase hex). Pure, no I/O.

(require racket/contract/base
         "../errors/error-type.rkt")

(provide
  (contract-out
   ;; any -> boolean, 40 or 64 lowercase hex chars?
   [git-id? (-> any/c boolean?)]
   ;; string -> string, identity on success, kind 'spec with the string on failure
   [string->git-id (-> string? string?)]))

;; ---------------------------------------------------------------------------
;; Validation

;; any -> boolean, 40 hex (git) or 64 hex (sha256 repos), lowercase only
(define (git-id? v)
  (and (string? v)
       (let ((n (string-length v)))
         (and (or (= n 40) (= n 64))
              (for/and ([c (in-string v)])
                (or (and (char<=? #\0 c) (char<=? c #\9))
                    (and (char<=? #\a c) (char<=? c #\f))))))))

;; string -> string, identity on success
(define (string->git-id s)
  (if (git-id? s)
      s
      (raise-pm-error 'spec 'string->git-id "not a commit id"
                      #:fields `(("value" . ,s)))))