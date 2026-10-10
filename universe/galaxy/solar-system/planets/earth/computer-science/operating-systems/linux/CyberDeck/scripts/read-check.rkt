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

(require racket/file
         racket/list
         racket/string)

(define files (vector->list (current-command-line-arguments)))

(define (bad-at f line msg)
  (printf "READ-BAD ~a:~a ~a\n" f line msg)
  (flush-output)
  #f)

;; How many leading lines to drop: an optional shebang, then an optional
;; #lang. Both are legal only at the very start of a file, so dropping at
;; most those two can never hide a real form.
(define (header-lines ls)
  (cond
    [(null? ls) 0]
    [(regexp-match? #px"^[ \t]*#!" (car ls)) (add1 (header-lines (cdr ls)))]
    [(regexp-match? #px"^[ \t]*#lang" (car ls)) 1]
    [else 0]))

;; Read every form of one file. Line numbers come from each form's own
;; srcloc plus the number of header lines dropped, so they match the file.
(define (read-one f)
  (define body (file->string f #:mode 'binary))
  (define ls (string-split body "\n"))
  (define skip (header-lines ls))
  (define in (open-input-string (string-join (drop ls skip) "\n")))
  (let loop ()
    (define v
      (with-handlers ([exn:fail? (lambda (e) (bad-at f skip (exn-message e)))])
        (read-syntax (make-base-namespace) in)))
    (cond
      [(eof-object? v) #t]
      [(not v) #f]
      [else (loop)])))

(define bad (filter (lambda (f) (not (read-one f))) files))
(printf "read-check: ~a files, ~a bad\n" (length files) (length bad))
(for ([f (in-list bad)]) (printf "READ-BAD-FILE ~a\n" f))
(exit (if (null? bad) 0 1))
