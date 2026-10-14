#lang racket/base
;; scripts/read-check.rkt -- structural check for every named .rkt.
;;
;; WHY THIS EXISTS. A blind line-delete once removed the BODY of
;; `(define (as-dir d)`, leaving the head hanging. Racket's reader then
;; reported "expected a `)` to close `(`" at the END of the file, which
;; is true and useless: the real problem was a bodyless define four
;; hundred lines earlier. Several rounds of paren counting followed,
;; each one "fixing" a line that was never wrong, because the reader was
;; short by exactly the parens the missing body needed.
;;
;; So this does TWO passes and the first one is the useful one:
;;
;;   1. A bracket-stack walk that knows about strings, `;` comments,
;;      `#\` character literals and `#| ... |#` blocks. It reports:
;;        - a bracket of the WRONG KIND, naming both lines
;;          ("found ] but ( opened at line 12")
;;        - EVERY unclosed opener, naming the line and printing the text
;;          that opened it -- which is what makes a bodyless define
;;          obvious at a glance
;;        - a top-level `(define (name ...)` that is followed by another
;;          top-level form instead of a body, which is the exact shape
;;          of the bug that cost the afternoon
;;   2. Racket's own reader, which stays the authority on whether the
;;      file is valid.
;;
;; Prints "read-check: N files, M bad" and exits 1 if anything is bad.
;; No timers, no polling (D-015). Files come from argv; check.nu globs.

(require racket/file
         racket/list
         racket/port
         racket/string)

(define files (vector->list (current-command-line-arguments)))

(define (emit . xs)
  (apply printf xs)
  (newline)
  (flush-output))

;; ---------------------------------------------------------------------------
;; Pass 1: the bracket stack.

(define opener->closer (hash '(#\( #\)) #\[ #\] #\{ #\}))
(define closer->opener (hash #\) #\( #\] #\[ #\} #\{))

;; string -> (listof (list line col char-kind))
;; kind is one of: 'open, 'close, 'mismatch, 'unclosed
;; Scanning is done with a hand-rolled walk so we can see past the
;; constructs that would otherwise hide brackets.
(define (scan s)
  (let loop ([i 0] [line 1] [col 1] [stack '()] [out '()])
    (cond
      [(>= i (string-length s))
       (append (reverse (for/list ([e (in-stack stack)])
                          (list (car e) (cadr e) 'unclosed (cadddr e))))
               (reverse out))]
      [else
       (define c (string-ref s i))
       (cond
         ;; line comment
         [(char=? c #\;)
          (let skip ([j i] [l line] [k col])
            (cond [(>= j (string-length s)) (loop j l k stack out)]
                  [(char=? (string-ref s j) #\newline) (loop (add1 j) (add1 l) 1 stack out)]
                  [else (skip (add1 j) l (add1 k) j)]))]
         ;; block comment, possibly nested in Racket
         [(and (char=? c #\#) (< (add1 i) (string-length s))
               (char=? (string-ref s (add1 i)) #\|))
          (let skip ([j (+ i 2)] [l line] [k col] [depth 1])
            (cond
              [(>= j (string-length s)) (loop j l k stack out)]
              [(and (char=? (string-ref s j) #\|)
                    (< (add1 j) (string-length s))
                    (char=? (string-ref s (add1 j)) #\#))
               (skip (+ j 2) l (add1 k) (sub1 depth))]
              [(and (char=? (string-ref s j) #\#)
                    (< (add1 j) (string-length s))
                    (char=? (string-ref s (add1 j)) #\|))
               (skip (+ j 2) l (add1 k) (add1 depth))]
              [(char=? (string-ref s j) #\newline) (skip (add1 j) (add1 l) 1 stack out)]
              [else (skip (add1 j) l (add1 k) depth)]))]
         [(and (char=? c #\#) (< (add1 i) (string-length s))
               (char=? (string-ref s (add1 i)) #\\))
          ;; character literal: #\( #\) #\[ #\] #\; #\# etc
          (define j (+ i 2))
          (cond
            [(>= j (string-length s)) (loop j line (add1 col) stack out)]
            ;; #\newline and friends are two characters
            [(and (char=? (string-ref s j) #\u)
                  (< (add1 j) (string-length s)))
             (loop (min (+ j 2) (string-length s)) line (+ col 2) stack out)]
            [(char=? (string-ref s j) #\newline)
             (loop (add1 j) (add1 line) (+ col 2) stack out)]
            [else (loop (add1 j) line (add1 col) stack out)])]
         [(char=? c #\")
          (let str ([j (add1 i)] [l line] [k (add1 col)])
            (cond
              [(>= j (string-length s)) (loop j l k stack out)]
              [(char=? (string-ref s j) #\\) (str (min (+ j 2) (string-length s)) l (+ k 2))]
              [(char=? (string-ref s j) #\newline) (str (add1 j) (add1 l) 1)]
              [(char=? (string-ref s j) #\") (loop (add1 j) l (add1 k) stack out)]
              [else (str (add1 j) l (add1 k))]))]
         [(hash-has-key? opener->closer c)
          (loop (add1 i) line (add1 col)
                (cons (list c line col i) stack) out)]
         [(hash-has-key? closer->opener c)
          (cond
            [(null? stack)
             (loop (add1 i) line (add1 col) stack
                   (cons (list line col 'mismatch #f
                               (format "stray '~a' with nothing open" c))
                         out))]
            [else
             (define top (car stack))
             (define expected (opener->closer (car top)))
             (cond
               [(char=? expected c)
                (loop (add1 i) line (add1 col) (cdr stack) out)]
               [else
                (loop (add1 i) line (add1 col) (cdr stack)
                      (cons (list line col 'mismatch (cadr top)
                                  (format "found '~a' but '~a' opened at line ~a"
                                          c (car top) (cadr top)))
                            out))])])]
         [(char=? c #\newline)
          (loop (add1 i) (add1 line) 1 stack out)]
         [else (loop (add1 i) line (add1 col) stack out)])])))

;; string -> string, the text of a line, for naming an unclosed opener.
(define (line-text ls n)
  (if (and (>= n 1) (<= n (length ls))) (list-ref ls (sub1 n)) ""))

(define (check-structure f)
  (define body (file->string f #:mode 'binary))
  (define ls (string-split body "\n"))
  ;; drop a shebang and/or #lang: both are only legal at the very start
  (define skip
    (cond
      [(or (null? ls) (not (regexp-match? #px"^[ \t]*#!" (car ls)))) 0]
      [(and (> (length ls) 1) (regexp-match? #px"^[ \t]*#lang" (cadr ls))) 2]
      [else 1]))
  (define dropped (string-join (drop ls skip) "\n"))
  (define found (scan dropped))
  (define problems
    (for/list ([e (in-list found)]
               #:when (not (memq (cadddr e) '(open close))))
      e))
  (define bodies (bodyless-defines ls skip))
  (cond
    [(or (pair? problems) (pair? bodies))
     (for ([p (in-list problems)])
       (emit "READ-STRUCT ~a:~a ~a" f (car p) (cadddr p)))
     (for ([b (in-list bodies)])
       (emit "READ-STRUCT ~a:~a (define ( ~a ... ) has no body: the next"
             f (car b) (cadr b))
       (emit "             line ~a starts a new form instead: ~a"
             (cadddr b) (line-text ls (cadddr b))))
     #f]
    [else #t]))

;; (listof string) -> (listof (list line name next-line))
;; A top-level `(define (NAME ...` whose following non-blank,
;; non-comment line does not continue it. This is the shape a blind
;; delete leaves behind, and it is invisible to a plain paren count.
(define (bodyless-defines ls skip)
  (define n (length ls))
  (define (top-open? s)
    (and (regexp-match? #px"^\\((define|define-values|define-syntax) \\(" s)
         #t))
  (define (name-of s)
    (define m (regexp-match #px"^\\((?:define|define-values|define-syntax) \\(([^ \t()]+)" s))
    (and m (cadr m)))
  (define (starts-form? s)
    (or (regexp-match? #px"^[()]" s) (regexp-match? #px"^\\[\\)" s)))
  (let loop ([i skip] [depth 0] [out '()])
    (cond
      [(>= i n) (reverse out)]
      [else
       (define s (list-ref ls i))
       (cond
         [(or (string-blank? s)
              (regexp-match? #px"^[ \t]*;;" s)
              (regexp-match? #px"^[ \t]*$" s))
          (loop (add1 i) depth out)]
         [else
          (define opens (count-opens s))
          (define closes (count-closes s))
          (define nd (+ depth opens (- closes)))
          (cond
            [(and (= depth 0) (top-open? s) (= nd 1))
             ;; find the next line with content
             (define j (next-content i))
             (cond
               [(and (< j n) (starts-form? (list-ref ls j)))
                (loop (add1 i) nd
                      (cons (list (+ i 1 skip) (name-of s) (+ j 1 skip)) out))]
               [else (loop (add1 i) nd out)])]
            [else (loop (add1 i) nd out)])])])))
(define (next-content i)
  (let loop ([j i])
    (cond
      [(>= j (length ls)) j]
      [(let ([s (list-ref ls j)])
         (or (string-blank? s)
             (regexp-match? #px"^[ \t]*;;" s)
             (regexp-match? #px"^[ \t]*$" s)))
       (loop (add1 j))]
      [else j])))
(define (count-opens s) (count-chars s '(#\( #\[ #\{)))
(define (count-closes s) (count-chars s '(#\) #\] #\})))
(define (count-chars s cs)
  (for/sum ([c (in-string s)] #:when (memv c cs)) 1))

;; ---------------------------------------------------------------------------
;; Pass 2: Racket's own reader stays the authority.

(define (read-one f)
  (define body (file->string f #:mode 'binary))
  (define ls (string-split body "\n"))
  (define skip
    (cond
      [(or (null? ls) (not (regexp-match? #px"^[ \t]*#!" (car ls)))) 0]
      [(and (> (length ls) 1) (regexp-match? #px"^[ \t]*#lang" (cadr ls))) 2]
      [else 1]))
  (define dropped (string-join (drop ls skip) "\n"))
  (define in (open-input-string dropped))
  (define (line-at pos)
    (define prefix (substring dropped 0 (min pos (string-length dropped))))
    (+ skip 1 (length (or (regexp-match* #rx"\n" prefix) '()))))
  (let loop ()
    (define pos (port-position in))
    (define v
      (with-handlers
          ([exn:fail?
            (lambda (e)
              (printf "READ-BAD ~a:~a ~a\n" f (line-at pos) (exn-message e))
              (flush-output)
              #f)])
        (read-syntax (make-base-namespace) in)))
    (cond
      [(eof-object? v) #t]
      [(not v) #f]
      [else (loop)])))

(define (check-one f)
  (and (check-structure f) (read-one f)))

(define bad (filter (lambda (f) (not (check-one f))) files))
(printf "read-check: ~a files, ~a bad\n" (length files) (length bad))
(for ([f (in-list bad)]) (printf "READ-BAD-FILE ~a\n" f))
(exit (if (null? bad) 0 1))