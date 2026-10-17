#lang racket/base
;; resolve-test.rkt -- the moved-out test submodule of src/spec/resolve.rkt.
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
            "../../src/entry/version.rkt"
            "../../src/spec/spec.rkt"
         "../../src/spec/resolve.rkt")

(module+ test
  (require rackunit
           "../../src/errors/error-type.rkt"
           "../../src/entry/version.rkt"
           "../../src/spec/spec.rkt")

  ;; spec symbol string (listof (list symbol string)) -> spec
  (define (test-spec name ver deps)
    (spec name (string->version ver) "test package"
          (source "https://example.org/x.git"
                  "9edb3f66fd807b096b48283debdcddccfea34bad")
          (map (lambda (d) (dep (car d) (string->version (cadr d))))
               deps)
          '()
          (list (build-step 'copy '("a" "b")))
          (install-spec 'prefix '())
          'mit "https://example.org" #f '() '()
          'default '()))

  ;; Linear chain resolves dependency-first.
  (define chain-c (test-spec 'c "1.0" '()))
  (define chain-b (test-spec 'b "1.0" '((c "1.0"))))
  (define chain-a (test-spec 'a "1.0" '((b "1.0"))))
  (check-equal? (map spec-name (resolve (list chain-a chain-b chain-c)
                                        (list chain-a)))
                '(c b a))

  ;; Diamonds emit the shared dep once, first encounter wins.
  (define dia-a (test-spec 'a "1.0" '()))
  (define dia-b (test-spec 'b "1.0" '((a "1.0"))))
  (define dia-c (test-spec 'c "1.0" '((a "1.0"))))
  (define dia-d (test-spec 'd "1.0" '((b "1.0") (c "1.0"))))
  (check-equal? (map spec-name (resolve (list dia-d dia-c dia-b dia-a)
                                        (list dia-d)))
                '(a b c d))

  ;; Empty roots resolve empty.
  (check-equal? (resolve (list chain-a) '()) '())

  ;; Exact message for a missing dep (design-doc sample).
  (define pkg-a (test-spec 'pkg-alpha "4.0.0" '((pkg-beta "1.0.0"))))
  (check-equal?
   (with-handlers ([exn:fail:pm? exn-message])
     (resolve (list pkg-a) (list pkg-a))
     "NO-ERROR")
   (string-append "resolve: unsatisfiable dependency;\n"
                  "  package: pkg-alpha 4.0.0\n"
                  "  dep: pkg-beta 1.0.0\n"
                  "  hint: no spec provides pkg-beta 1.0.0"))

  ;; Equality only: pkg-beta 2.0 does not satisfy 1.0.
  (define compat-2 (test-spec 'pkg-beta "2.0" '()))
  (check-pred resolve-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (resolve (list pkg-a compat-2) (list pkg-a))
                'no-error))

  ;; Cycles name the chain and raise kind 'resolve.
  (define cyc-alpha (test-spec 'pkg-cycle-a "1.0" '((pkg-cycle-b "1.0"))))
  (define cyc-beta (test-spec 'pkg-cycle-b "1.0" '((pkg-cycle-a "1.0"))))
  (define cycle-error
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (resolve (list cyc-alpha cyc-beta) (list cyc-alpha))
      'no-error))
  (check-pred resolve-error? cycle-error)
  (check-regexp-match #rx"dependency cycle" (exn-message cycle-error))
  (check-regexp-match #rx"pkg-cycle-a 1.0" (exn-message cycle-error)))

