#lang racket/base
;; One job: a name and its body reach the right meaning.
;; Registered in plan/package-tree.org (elements/dispatch.rkt). Lands with
;; TODO item 3.
;;
;; Dispatch is the only door from a name to a meaning. It looks the name up in
;; register.rkt and refuses anything unregistered; it never guesses, and it
;; never creates a meaning of its own.

(require "register.rkt"
         "literals.rkt")

(provide meaning-of opaque? dispatch dispatch-line)


;; meaning-of returns the registered meaning of a name, and raises when the
;; name is not registered. The caller is a stage, so the error names the file's
;; problem and what to do.
(define (meaning-of name)
  (require-known name)
  (element-kind (element-for name)))

;; opaque? says whether the parser must not read this block's body as
;; notation. Only code blocks are opaque (rule D).
(define (opaque? name)
  (require-known name)
  (element-opaque? (element-for name)))

;; dispatch takes the name and the body lines and returns the registered
;; meaning. The body is handed back untouched: this area reads names, it never
;; rewrites text.
(define (dispatch name body-lines)
  (require-known name)
  (list (cons 'name name)
        (cons 'meaning (meaning-of name))
        (cons 'opaque (opaque? name))
        (cons 'body body-lines)))

;; dispatch-line is the same thing for one line of a file: it says which
;; meaning the line carries, if any. A line that is not a block line gets 'none
;; and is left alone, because content belongs to the block that is open, not to
;; the vocabulary.
(define (dispatch-line line)
  (define name (name-of line))
  (cond
    [(not name) 'none]
    [(known-name? name) (meaning-of name)]
    [else 'unknown]))