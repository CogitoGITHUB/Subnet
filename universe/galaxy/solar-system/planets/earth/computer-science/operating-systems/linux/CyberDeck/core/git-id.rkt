#lang racket/base
;; git-id.rkt -- commit id validation (40/64 lowercase hex). Pure, no I/O.

(require racket/contract/base
         "errors.rkt")

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

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit)

  ;; Real shapes pass through unchanged.
  (check-equal? (string->git-id "9edb3f66fd807b096b48283debdcddccfea34bad")
                "9edb3f66fd807b096b48283debdcddccfea34bad")
  (check-equal? (string->git-id (make-string 64 #\a))
                (make-string 64 #\a))
  (check-true (git-id? (make-string 40 #\0)))
  (check-false (git-id? "9EDB3F66FD807B096B48283DEBDCDDCCFEA34BAD"))
  (check-false (git-id? ""))
  (check-false (git-id? (make-string 39 #\a)))
  (check-false (git-id? (make-string 41 #\a)))
  (check-false (git-id? (make-string 63 #\a)))
  (check-false (git-id? (make-string 65 #\a)))
  (check-false (git-id? 42))
  (check-false (git-id? #f))

  ;; Failures raise kind 'spec carrying the bad string, exit code 3.
  (define bad
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (string->git-id "xyz")))
  (check-pred spec-error? bad)
  (check-equal? (exn:fail:pm-fields bad) '(("value" . "xyz")))
  (check-equal? (pm-error-exit-code bad) 3))
