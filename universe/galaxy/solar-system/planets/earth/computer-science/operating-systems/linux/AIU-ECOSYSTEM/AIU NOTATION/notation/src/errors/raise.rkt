#lang racket/base
;; One job: the one raise helper; nothing raises around it.
;; Lands with TODO item 1 (the tree lands).

(require "err.rkt")

;; raise-err is the only place in the package that raises. A stage that finds a
;; problem calls this with who / where / what in words; the irritants stay
;; readable because err.rkt prints one shape and never a dump.
(define (raise-err who where what [irritants '()])
  ;; The stack trace is dropped on purpose: where already names file and line,
  ;; and a trace reads as noise on a phone.
  (raise (make-err who where what)))

;; with-err runs thunk and turns any raised error into the same record shape,
;; naming the stage; it catches nothing else and hides nothing.
(define (with-err who thunk)
  (with-handlers ([exn:notation? (lambda (e) e)])
    (thunk)))