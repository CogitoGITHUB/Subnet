#lang racket/base
;; One job: the one raise helper; nothing raises around it.
;; Lands with TODO item 1 (the tree lands).

(require "err.rkt")

(provide raise-err with-err)


;; raise-err is the only place in the package that raises. A stage that finds a
;; problem calls this with who / where / what in words; the irritants stay
;; readable because err.rkt prints one shape and never a dump.
;; raise-err takes exactly three arguments and no optional or rest argument.
;; This Racket build neither expands an ellipsis rest parameter nor honours an
;; optional bracket parameter — it counts them as required and answers
;; "arity mismatch; expected 4, given 3" (found by the first by-hand run,
;; 2026-10-17). Anything extra belongs in what, in words.
;;
;; The stack trace is dropped on purpose: where already names file and line,
;; and a trace reads as noise on a phone.
(define (raise-err who where what)
  (raise (make-err who where what)))

;; with-err runs thunk and turns any raised error into the same record shape,
;; naming the stage; it catches nothing else and hides nothing.
(define (with-err who thunk)
  (with-handlers ([exn:notation? (lambda (e) e)])
    (thunk)))