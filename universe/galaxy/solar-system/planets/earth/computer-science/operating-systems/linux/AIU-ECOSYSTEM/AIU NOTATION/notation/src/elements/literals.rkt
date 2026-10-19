#lang racket/base
;; One job: literal names — what a name is, what it is not.
;; Registered in plan/package-tree.org (elements/literals.rkt). Lands with
;; TODO item 3.
;;
;; A block name is written as a bare lowercase word: no symbol, no quotes, no
;; angle brackets. This file is the one place that decides what counts.

(require racket/list
         racket/string)

;; Provided with TODO item 5: diagnostics/collect.rkt asks literal-name? what
;; a tag is, so no second place decides what a name looks like.
(provide name-char? literal-name? name-of start-line? end-line?)

;; name-char? says whether a character may appear in a name. Names stay plain
;; lowercase words so they read the same in text, in a message and on a phone
;; keyboard.
(define (name-char? c)
  (or (char-alphabetic? c) (char=? c #\-)))

;; literal-name? says whether a string is a well-formed name: non-empty, all
;; name characters, no leading or trailing dash.
(define (literal-name? s)
  (and (string? s)
       (> (string-length s) 0)
       (not (char=? (string-ref s 0) #\-))
       (not (char=? (string-ref s (- (string-length s) 1)) #\-))
       (andmap name-char? (string->list s))))

;; name-of returns the name a "<name> start" or "<name> end" line carries, or
;; #f when the line is not a block line at all. It reads the name and nothing
;; else; it does not decide whether the name is registered.
(define (name-of line)
  (define parts (string-split (string-trim line) " " #:trim? #t #:repeat? #t))
  (and (= (length parts) 2)
       (or (string=? (second parts) "start") (string=? (second parts) "end"))
       (first parts)))

;; start-line? and end-line? say which of the two a block line is. A name on its
;; own, with neither word, is not a block line.
(define (start-line? line)
  (define n (name-of line))
  (and n (string=? (second (string-split (string-trim line) " " #:trim? #t #:repeat? #t)) "start")))

;; end-line? says whether a line closes a block, so a reader can tell
;; the two kinds of block line apart.
;; end-line? is the closing half of the pair: it answers only for a "<name> end"
;; line, and #f for a start line or anything else.
(define (end-line? line)
  (define n (name-of line))
  (and n (string=? (second (string-split (string-trim line) " " #:trim? #t #:repeat? #t)) "end")))