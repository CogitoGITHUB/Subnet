#lang racket/base
;; core/test-park.rkt -- one named test can stand down, visibly.
;;
;; A shared-process runner cannot skip a single top-level expression inside
;; a test submodule by itself: requiring that submodule RUNS every
;; expression in it. So parking is cooperative. This module owns the one
;; parameter that says which names are standing down, and the one predicate
;; a test uses to ask.
;;
;; The list is deliberately data, never logic: the gate (scripts/check.nu)
;; holds PARKED as (file, test name, reason) and passes the names down, so
;; the reason a test is parked lives with the gate that parks it, not
;; hidden in the test.
;;
;; A parked test is NOT a passing test. The gate reports parked tests in its
;; verdict line and prints one line per parked item with its reason, so a
;; parked test is never silently absent from a green run. Nothing here waits
;; on anything (D-015).

(require racket/set)

(provide
 ;; parameter, (setof string?) -> (setof string?), names standing down
 current-parked-tests
 ;; string -> boolean, the helper a test actually calls
 test-parked?)

;; Default: none, so a plain `raco test` of one file runs everything.
(define current-parked-tests (make-parameter (set)))

;; string -> boolean, true when NAME is standing down right now.
(define (test-parked? name)
  (set-member? (current-parked-tests) name))
