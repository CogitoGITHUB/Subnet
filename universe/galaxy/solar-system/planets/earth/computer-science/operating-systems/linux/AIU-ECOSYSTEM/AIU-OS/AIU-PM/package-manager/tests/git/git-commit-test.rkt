#lang racket/base
;; git-commit-test.rkt -- the moved-out test submodule of src/git/git-commit.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            "../../src/errors/error-type.rkt"
         "../../src/git/git-commit.rkt")

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

