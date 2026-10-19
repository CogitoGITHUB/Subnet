#lang racket/base
;; spec-test.rkt -- the moved-out test submodule of src/spec/spec.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            "../../src/errors/error-type.rkt"
            "../../src/spec/version.rkt"
            "../../src/git/git-commit.rkt"
         "../../src/spec/spec.rkt")

(module+ test
  (require rackunit)

  ;; Names accept D-8, reject the rest.
  (check-true (package-name? 'pkg-alpha))
  (check-true (package-name? 'a))
  (check-false (package-name? 'Bad!))
  (check-false (package-name? 'a/b))
  (check-false (package-name? "pkg-alpha"))
  (check-false (package-name? ""))

  ;; Slot names accept letters, digits, dot, underscore, dash.
  (check-true (slot-name? 'lts))
  (check-true (slot-name? 'default))
  (check-true (slot-name? 'gtk3))
  (check-false (slot-name? 'Bad!))
  (check-false (slot-name? "lts"))
  (check-false (slot-name? 42))

  ;; Flag declarations accept sound values (rejections pinned next to the
  ;; other guard tests below, after the spec-kind helper they call).
  (check-true (flag-spec? (flag-spec 'gui #t "GUI" '() '())))

  ;; A full valid spec builds.
  (define good
    (spec 'pkg-alpha (string->version "20250115.1432") "Alpha test package"
          (source "https://example.org/r.git"
                  "9edb3f66fd807b096b48283debdcddccfea34bad")
          (list (dep 'pkg-beta (string->version "1.0")))
          '()
          (list (build-step 'copy '("a" "b")))
          (install-spec 'prefix '((bin "b")))
          'gpl-3.0+ "https://example.org/r" #f '() '()
          'lts
          (list (flag-spec 'gui #t "Graphical interface" '(minimal) '(x11)))))
  (check-true (spec? good))
  (check-equal? (spec-name good) 'pkg-alpha)
  (check-equal? (spec-slot good) 'lts)
  (check-equal? (map flag-spec-name (spec-flags good)) '(gui))

  ;; Every guard rejects with kind 'spec.
  (define (spec-kind thunk)
    (with-handlers ([exn:fail:pm? exn:fail:pm-kind])
      (thunk)
      #f))
  (check-eq? (spec-kind (lambda () (source "" "abc"))) 'spec)
  (check-eq? (spec-kind (lambda () (source "u" "XYZ"))) 'spec)
  (check-eq? (spec-kind (lambda () (dep 'Bad! good))) 'spec)
  (check-eq? (spec-kind (lambda () (install-spec 'web '()))) 'spec)
  (check-eq? (spec-kind
              (lambda ()
                (struct-copy spec good [name 'Bad!]))) 'spec)
  (check-eq? (spec-kind
              (lambda ()
                (struct-copy spec good [extends 'Bad!]))) 'spec)
  (check-eq? (spec-kind
              (lambda ()
                (struct-copy spec good [slot 'Bad!]))) 'spec)
  (check-eq? (spec-kind
              (lambda ()
                (struct-copy spec good [flags '(not-structs)]))) 'spec)
  (check-eq? (spec-kind (lambda () (flag-spec 'Bad! #t "GUI" '() '())))
             'spec)
  (check-eq? (spec-kind (lambda () (flag-spec 'gui "yes" "GUI" '() '())))
             'spec)
  (check-eq? (spec-kind (lambda () (flag-spec 'gui #t "" '() '())))
             'spec)
  (check-eq? (spec-kind
              (lambda () (flag-spec 'gui #t "GUI" '(Bad!) '())))
             'spec))

