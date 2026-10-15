#lang racket/base
;; spec-typos.rkt -- edit distance and "did you mean": the text utility
;; behind every unknown-key complaint (pure, no I/O).
;;
;; Split out of spec-read.rkt, which did four jobs in one file. This one
;; is the bottom of the split: it knows about strings and nothing else,
;; and it depends on nothing else in the tree.
;;
;; The candidate keys arrive as an argument instead of living here. A
;; typo helper that also owned the field table would be two jobs in one
;; file, and the closed key list would have two possible homes. The key
;; table stays in spec-fields.rkt, which owns it.

(provide
 ;; string string -> exact-integer, classic edit distance
 levenshtein
 ;; (listof symbol) symbol -> string, closest key within 2 edits, or ""
 suggest-key)

;; string string -> exact-integer, classic edit distance
(define (levenshtein a b)
  (define la (string-length a))
  (define lb (string-length b))
  (define prev (for/vector ([j (in-range (+ lb 1))]) j))
  (for ([i (in-range 1 (+ la 1))])
    (define cur (make-vector (+ lb 1) 0))
    (vector-set! cur 0 i)
    (for ([j (in-range 1 (+ lb 1))])
      (vector-set! cur j
                   (min (+ (vector-ref prev j) 1)
                        (+ (vector-ref cur (- j 1)) 1)
                        (+ (vector-ref prev (- j 1))
                           (if (char=? (string-ref a (- i 1))
                                       (string-ref b (- j 1)))
                               0 1)))))
    (set! prev cur))
  (vector-ref prev lb))

;; (listof symbol) symbol -> string, closest known key within 2 edits, or ""
(define (suggest-key keys head)
  (define s (symbol->string head))
  (define best #f)
  (define best-d 3)
  (for ([k (in-list keys)])
    (define d (levenshtein s (symbol->string k)))
    (when (< d best-d)
      (set! best k)
      (set! best-d d)))
  (if best
      (format " (did you mean '~a?)" best)
      ""))
