#lang racket/base
;; scripts/read-check.rkt -- read every named .rkt and report the exact
;; file and line of the first malformed form, so an unbalanced paren is
;; NAMED instead of guessed at. Runs before anything is compiled or
;; tested, so a bad edit is caught by the gate and not by a later crash.
;;
;; Files come from argv; the caller (scripts/check.nu) already globs the
;; tree, so this module never has to walk directories itself.
;;
;; Prints "read-check: N files, M bad", one "READ-BAD <file>:<line>
;; <message>" per bad file, and exits 1 if anything is bad.
;; No timers, no polling (D-015).

(require racket/file)

(define files (vector->list (current-command-line-arguments)))

;; Read every form in one file. Print the first bad form with its line
;; number; return #t when the whole file reads cleanly.
(define (read-one f)
  (call-with-input-file f
    (lambda (in)
      (let loop ([line 1])
        (define v (with-handlers
                       ([exn:read?
                         (lambda (e)
                           (printf "READ-BAD ~a:~a ~a\n" f line (exn-message e))
                           #f)])
                       (read-syntax (make-base-namespace) in)))
        (cond [(eof-object? v) #t]
              [(not v) #f]
              [else (loop (add1 line))])))
    #:mode 'binary))

(define bad (filter (lambda (f) (not (read-one f))) files))
(printf "read-check: ~a files, ~a bad\n" (length files) (length bad))
(for ([f (in-list bad)]) (printf "READ-BAD-FILE ~a\n" f))
(exit (if (null? bad) 0 1))
