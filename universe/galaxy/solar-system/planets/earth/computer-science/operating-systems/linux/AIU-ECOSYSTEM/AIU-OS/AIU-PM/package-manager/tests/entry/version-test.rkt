#lang racket/base
;; version-test.rkt -- the moved-out test submodule of src/entry/version.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            racket/string
            "../../src/errors/error-type.rkt"
         "../../src/entry/version.rkt")

(module+ test
  (require rackunit)

  ;; Numeric compare is numeric: "1.10" > "1.9".
  (check-true (version>? (string->version "1.10") (string->version "1.9")))
  (check-true (version<? (string->version "2.9") (string->version "2.9.1")))
  (check-true (version>? (string->version "20250116.1")
                         (string->version "20250115.1432")))

  ;; "1.0" vs "1.0.0": recorded choice is equal (missing parts count as 0).
  (check-true (version=? (string->version "1.0") (string->version "1.0.0")))
  (check-equal? (version-compare (string->version "1.0")
                                 (string->version "1.0.0"))
                0)

  ;; Round-trips print the original text.
  (for ([s (in-list '("2.9.1" "20250115.1432" "main" "v1.2.3" "01.2"))])
    (check-equal? (version->string (string->version s)) s))

  ;; Labels match by equality only.
  (check-true (version-matches? (string->version "main")
                                (string->version "main")))
  (check-false (version-matches? (string->version "main")
                                 (string->version "dev")))

  ;; Hostile inputs raise kind 'spec with the offending string.
  (for ([s (in-list '("" "1..2" "-1" ".5" "1."))])
    (check-exn exn:fail:pm? (lambda () (string->version s))))
  (check-exn #rx"1\\.\\.2"
             (lambda () (string->version "1..2")))
  (check-pred spec-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (string->version "-1"))))

