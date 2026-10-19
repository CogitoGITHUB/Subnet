#lang racket/base
;; One job: the paren check — READ-BAD file:line, the bad form named.
;; Registered in plan/package-tree.org; lands with TODO item 1.
;;
;; Usage (PM's way, AIU-OS/AIU-PM/AGENT.md:104):
;;   /root/home/shape/opt/racket-full/bin/racket gate/read-check.rkt <files...>
;;
;; It only reads. One line per file, exit non-zero if any file does not parse.
;; It never rewrites a file and never loads one.
;;
;; Two facts about this phone's Racket 9.3 install shape this file, each proved
;; by a command (2026-10-17):
;;   1. The ellipsis form in a parameter list does not expand here: a definition
;;      written "(define (f a b ...) ...)" counts "..." as a third parameter
;;      ("arity mismatch; expected 3"), while the dotted form "(define (f . xs)
;;      ...)" works and prints (1 2). So this package takes a list, never an
;;      ellipsis rest argument.
;;   2. Reading a #lang line through a plain string port fails here
;;      ("#lang not enabled"), so the header is dropped and the body is read in
;;      the base namespace — PM's way, AIU-OS/AIU-PM/gate/read-check.rkt:94-111.
;;
;; A reader error names where reading stopped, which for an unclosed form is
;; the end of the file. So on failure this also walks the raw text and prints
;; every form still open with its line: a head with nothing under it is then
;; obvious instead of four hundred lines away.

(require racket/file
         racket/list
         racket/string)

;; files is the list of file paths given on the command line, read once here so
;; every later step works on the same list.
(define files (vector->list (current-command-line-arguments)))

;; header-lines: how many leading lines to drop — a shebang, then a #lang.
;; Both are legal only at the very start, so dropping at most those two can
;; never hide a real form.
(define (header-lines ls)
  (cond
    [(null? ls) 0]
    [(regexp-match? #px"^[ \t]*#!" (car ls)) (add1 (header-lines (cdr ls)))]
    [(regexp-match? #px"^[ \t]*#lang" (car ls)) 1]
    [else 0]))

;; bad-at prints one READ-BAD line naming the file, the line and what went
;; wrong, so the caller has the bad form and where it starts.
(define (bad-at f line msg)
  (printf "READ-BAD ~a:~a ~a\n" f line msg))

;; unclosed-heads walks the raw text and returns every form still open, with
;; the line it was opened on. Only strings and ; comments are skipped.
(define (unclosed-heads body skip)
  (define out '())
  (for ([line (in-list (drop (string-split body "\n") skip))]
        [ln (in-naturals (add1 skip))])
    (define stack '())
    (define n (string-length line))
    (let loop ([i 0])
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
          [(memv c '(#\( #\[ #\{)) (set! stack (cons (list c ln line) stack))]
          [(memv c '(#\) #\] #\})) (unless (null? stack) (set! stack (cdr stack)))]
          [else (void)])
        (loop (add1 i))))
    (set! out (append (reverse stack) out)))
  out)

;; read-one reads one file and answers whether it parsed. On failure it prints
;; where reading stopped and every form still left open, so an unclosed head is
;; shown rather than hidden.
(define (read-one f)
  ;; file->string comes from racket/file and reads the bytes as written. (The
;; racket/port route works too — port->string is fine once racket/port is
;; required — but file->string says what it reads in one call.)
  (define raw
    (with-handlers ([exn:fail? (lambda (e) "")])
      (file->string f #:mode 'binary)))
  (define ls (string-split raw "\n"))
  (define skip (header-lines ls))
  (define dropped (string-join (drop ls skip) "\n"))
  ;; byte offset in the dropped text -> 1-based line in the real file
  (define (line-at pos)
    (define prefix (substring dropped 0 (min pos (string-length dropped))))
    (+ skip 1 (length (or (regexp-match* #rx"\n" prefix) '()))))
  (define in (open-input-string dropped))
  (let loop ()
    (define pos (file-position in))
    (define v
      (with-handlers
          ([exn:fail? (lambda (e) (bad-at f (line-at pos) (exn-message e)) #f)])
        (read-syntax (make-base-namespace) in)))
    (cond
      [(eof-object? v) #t]
      [(not v)
       (for ([e (in-list (unclosed-heads raw skip))])
         (printf "READ-UNCLOSED ~a '~a' opened at line ~a: ~a\n"
                 f (car e) (cadr e)
                 (let ([s (caddr e)]) (substring s 0 (min 70 (string-length s))))))
       #f]
      [else (loop)])))

(if (null? files)
    (begin
      (printf "READ-BAD no files given; nothing checked is not a pass\n")
      (exit 1))
    (let ([bad (filter (lambda (f) (not (read-one f))) files)])
      (printf "read-check: ~a files, ~a bad\n" (length files) (length bad))
      (exit (if (null? bad) 0 1))))