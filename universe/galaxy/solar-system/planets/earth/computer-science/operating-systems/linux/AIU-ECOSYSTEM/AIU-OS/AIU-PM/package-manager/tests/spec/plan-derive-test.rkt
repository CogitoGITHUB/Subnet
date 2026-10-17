#lang racket/base
;; plan-derive-test.rkt -- the moved-out test submodule of src/spec/plan-derive.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/list
            "../../src/errors/error-type.rkt"
            "../../src/spec/flags.rkt"
            "../../src/spec/resolve.rkt"
            "../../src/spec/spec.rkt"
            "../../src/entry/version.rkt"
            ;; check-string-fields is provided by plan-actions.rkt and
            ;; re-provided by plan-derive.rkt; the module under test's
            ;; copy wins, so the copied module gives it up (D-046).
            (except-in "../../src/spec/plan-actions.rkt"
                       check-string-fields)
            "../../src/spec/plan-hash.rkt"
         "../../src/spec/plan-derive.rkt")

(module+ test
  (require rackunit
           "../../src/errors/error-type.rkt"
           "../../src/spec/spec.rkt"
           "../../src/entry/version.rkt")

  ;; E-04 fixtures: pkg-alpha on pkg-beta, synthetic and local (T-10).
  (define alpha-spec
    (spec 'pkg-alpha (string->version "2.0") "Alpha"
          (source "https://example.org/alpha.git"
                  "9edb3f66fd807b096b48283debdcddccfea34bad")
          (list (dep 'pkg-beta (string->version "1.0")))
          '()
          (list (build-step 'copy '("a" "b")))
          (install-spec 'prefix '((bin "alpha" "bin/alpha")
                                  (check "bin/alpha" "--version")))
          'mit "https://example.org/alpha" #f '() '()
          'default
          (list (flag-spec 'gui #t "GUI" '() '()))))
  (define beta-spec
    (spec 'pkg-beta (string->version "1.0") "Beta"
          (source "https://example.org/beta.git"
                  "8edb3f66fd807b096b48283debdcddccfea34bad")
          '() '()
          (list (build-step 'copy '("c" "d")))
          (install-spec 'prefix '((bin "beta" "bin/beta")))
          'mit "https://example.org/beta" #f '() '()
          'default
          '()))
  (define alpha-plan
    (derive-package-plan alpha-spec '((gui . #t)) '("pkg-beta 1.0")))

  ;; The input hash covers flags: flipping one flips the hash.
  (define alpha-off
    (derive-package-plan alpha-spec '((gui . #f)) '("pkg-beta 1.0")))
  (check-false (equal? (package-plan-input-hash alpha-plan)
                       (package-plan-input-hash alpha-off)))

  ;; derive-plans orders deps first; cycles raise kind 'resolve.
  (check-equal? (map package-plan-name
                     (derive-plans (list alpha-spec beta-spec) '() '()))
                '(pkg-beta pkg-alpha))
  (define cycle-spec
    (struct-copy spec alpha-spec
                 [name 'pkg-cycle-a]
                 [deps (list (dep 'pkg-cycle-a
                                  (string->version "2.0")))]))
  (check-pred resolve-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (derive-plans (list cycle-spec) '() '())
                'no-error))

  ;; Flags from another spec are caller error, kind 'config.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (derive-package-plan alpha-spec '((nope . #t))
                                     '("pkg-beta 1.0"))
                'no-error)))

