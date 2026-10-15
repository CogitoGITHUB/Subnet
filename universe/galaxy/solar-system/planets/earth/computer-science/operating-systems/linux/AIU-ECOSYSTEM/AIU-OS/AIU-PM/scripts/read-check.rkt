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

;; ---------------------------------------------------------------------------
;; Name the unclosed form.
;;
;; When Racket's reader fails it says "expected a `)` to close `(`" and
;; points where reading STOPPED -- for an unclosed form, the end of the
;; file. That is true and close to useless. A blind line-delete once left
;; `(define (as-dir d)` with no body under it; the reader complained at
;; the end of a 1200-line file, and several rounds of paren counting
;; followed, each one editing a line that was never wrong.
;;
;; So on failure we also walk the raw text and print the head of every
;; form still open, with its line. A head with nothing under it is then
;; obvious instead of four hundred lines away.
;;
;; Only strings and `;` comments are skipped: a bracket inside either is
;; the usual false positive.

(define (unclosed-heads f)
  (define out '())
  (for ([line (in-list (string-split (file->string f #:mode 'binary) "\n"))]
        [ln (in-naturals 1)])
    (define stack '())
    (define i 0)
    (define n (string-length line))
    (let loop ()
      (when (< i n)
        (define c (string-ref line i))
        (cond
          [(char=? c #\;) (void)]
          [(char=? c #\")
           (let str ([j (add1 i)])
             (cond
               [(>= j n) (void)]
               [(char=? (string-ref line j) #\\) (str (+ j 2))]
               [(char=? (string-ref line j) #\") (set! i (add1 j))]
               [else (str (add1 j))]))]
          [(memv c '(#\( #\[ #\{))
           (set! stack (cons (list c ln line) stack))]
          [(memv c '(#\) #\] #\}))
           (unless (null? stack) (set! stack (cdr stack)))]
          [else (void)])
        (set! i (add1 i))
        (loop)))
    (set! out (append (reverse stack) out)))
  out)

(define (report-unclosed f)
  (for ([e (in-list (unclosed-heads f))])
    (printf "READ-UNCLOSED ~a '~a' opened at line ~a: ~a\n"
            f (car e) (cadr e)
            (let ([s (caddr e)])
              (substring s 0 (min 70 (string-length s))))))
  (flush-output))

;; How many leading lines to drop: an optional shebang, then an optional
;; #lang. Both are legal only at the very start of a file, so dropping at
;; most those two can never hide a real form.
(define (header-lines ls)
  (cond
    [(null? ls) 0]
    [(regexp-match? #px"^[ \t]*#!" (car ls)) (add1 (header-lines (cdr ls)))]
    [(regexp-match? #px"^[ \t]*#lang" (car ls)) 1]
    [else 0]))

;; Read every form of one file. The line is computed from the port offset
;; where the failing form STARTS (the reader skips blank space first, so
;; this lands within a line or two of a stray paren), plus the header
;; lines dropped above, so it matches the file. The old code passed
;; `skip` here, which always printed :1 and never named anything.
(define (read-one f)
  (define body (file->string f #:mode 'binary))
  (define ls (string-split body "\n"))
  (define skip (header-lines ls))
  (define dropped (string-join (drop ls skip) "\n"))
  (define in (open-input-string dropped))
  ;; byte offset -> 1-based file line number
  (define (line-at pos)
    (define prefix
      (substring dropped 0 (min pos (string-length dropped))))
    (+ skip 1 (length (or (regexp-match* #rx"\n" prefix) '()))))
  (let loop ()
    (define pos (file-position in))
    (define v
      (with-handlers ([exn:fail?
                        (lambda (e)
                          (bad-at f (line-at pos) (exn-message e))
                          (report-unclosed f)
                          #f)])
        (read-syntax (make-base-namespace) in)))
    (cond
      [(eof-object? v) #t]
      [(not v) #f]
      [else (loop)])))

(define bad (filter (lambda (f) (not (read-one f))) files))
(printf "read-check: ~a files, ~a bad\n" (length files) (length bad))
(for ([f (in-list bad)]) (printf "READ-BAD-FILE ~a\n" f))
(exit (if (null? bad) 0 1))
