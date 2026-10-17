#lang racket/base
;; plan-actions-test.rkt -- the moved-out test submodule of src/spec/plan-actions.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   "../../src/errors/error-type.rkt"
    "../../src/git/git-commit.rkt"
    "../../src/spec/spec.rkt"
    "../../src/entry/version.rkt"
         "../../src/spec/plan-actions.rkt")

(module+ test
  (require rackunit
           "../../src/errors/error-type.rkt")

  ;; Every action builds and predicates sort them.
  (define fetch-1
    (fetch-action "https://example.org/r.git" (make-string 40 #\a) "/tmp/s"))
  (check-true (action? fetch-1))
  (check-false (action? "fetch"))
  (check-false (action? 42))

  ;; Guards reject with kind 'internal (programmer-side construction).
  (define (internal-kind thunk)
    (with-handlers ([exn:fail:pm? exn:fail:pm-kind])
      (thunk)
      #f))
  (check-eq? (internal-kind (lambda () (fetch-action 42 "c" "d")))
             'internal)
  (check-eq? (internal-kind
              (lambda () (run-step-action "n" '() "d")))
             'internal)
  (check-eq? (internal-kind
              (lambda () (run-step-action "n" "not-a-list" "d")))
             'internal)
  (check-eq? (internal-kind
              (lambda () (install-file-action "s" "d" #o1000)))
             'internal)
  (check-eq? (internal-kind (lambda () (plan '(1 2 3)))) 'internal)
  (check-pred internal-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (plan '(oops)))))

