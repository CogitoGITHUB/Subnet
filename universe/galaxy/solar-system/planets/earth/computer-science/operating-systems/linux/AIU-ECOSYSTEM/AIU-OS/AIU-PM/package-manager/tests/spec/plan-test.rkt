#lang racket/base
;; plan-test.rkt -- the moved-out test submodule of src/spec/plan.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module itself:
;; plan.rkt re-provides every name this body uses out of
;; plan-actions.rkt, plan-conflicts.rkt, plan-derive.rkt,
;; plan-hash.rkt and plan-lower.rkt, so those five are dropped --
;; two modules providing one name in one require scope is a hard
;; error (D-046), and the body uses no name of theirs that plan.rkt
;; leaves out.

(require rackunit
         racket/contract/base
         "../../src/spec/spec.rkt"
         "../../src/spec/plan.rkt")

(module+ test
  (require rackunit
           "../../src/spec/spec.rkt"
           "../../src/spec/version.rkt")

  ;; E-04 fixture: pkg-alpha on pkg-beta, synthetic and local (T-10).
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

  ;; Two slots of one package plan to two store dirs.
  (define alpha-alt
    (struct-copy spec alpha-spec [slot 'lts]))
  (check-false (equal? (package-plan-store-dir
                        (derive-package-plan alpha-spec '((gui . #t))
                                             '("pkg-beta 1.0")))
                       (package-plan-store-dir
                        (derive-package-plan alpha-alt '((gui . #t))
                                             '("pkg-beta 1.0"))))))

