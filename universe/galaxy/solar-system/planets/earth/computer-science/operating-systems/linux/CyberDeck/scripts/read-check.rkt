#lang racket/base
;; scripts/read-check.rkt -- read every named .rkt and report the exact
;; file and line of the first malformed form, so an unbalanced paren is
;; NAMED instead of guessed at.
;;
;; Files come from argv. The caller (scripts/check.nu) already globs the
;; tree, so this module never walks directories itself.
;;
;; Prints "read-check: N files, M bad", one "READ-BAD <file>:<line>
;; <message>" per bad file, then exits 1 if anything is bad.
;; No timers, no polling (D-015).

(require racket/file)

(define files (vector->list (current-command-line-arguments)))

(define (bad-at f line msg)
  (printf "READ-BAD ~a:~a ~a\n" f line msg)
  (flush-output)
  #f)

;; Read every form of one file. A #lang line is module syntax that plain
;; read-syntax cannot read and it is legal only as the first form, so at
;; most one such line is skipped. A shebang is not a form at all.
(define (read-one f)
  (call-with-input-file f
    (lambda (in)
      (define first (read-line in 'any))
      (if (and first (regexp-match? #px"^[ \t]*#lang" first))
          (read-line in 'any)
          (void))
      (let loop ([line 2])
        (define v (with-handlers ([exn:fail? (lambda (e) (bad-at f line (exn-message e)))])
                     (read-syntax (make-base-namespace) in)))
        (cond [(eof-object? v) #t]
              [(not v) #f]
              [else (loop (add1 line))])))
    #:mode 'binary))

(define bad (filter (lambda (f) (not (read-one f))) files))
(printf "read-check: ~a files, ~a bad\n" (length files) (length bad))
(for ([f (in-list bad)]) (printf "READ-BAD-FILE ~a\n" f))
(exit (if (null? bad) 0 1))
