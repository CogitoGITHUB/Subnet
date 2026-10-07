#lang racket/base
;; version.rkt -- versions as labels with numeric compare where needed. Pure, no I/O.

(require racket/contract/base
         racket/string
         "errors.rkt")

(provide
 (struct-out version)
 (contract-out
  ;; string -> version, bad input raises kind 'spec with the string
  [string->version (-> string? version?)]
  ;; version -> string, the original text verbatim
  [version->string (-> version? string?)]
  ;; version version -> -1/0/1; numeric compare where both numeric
  [version-compare (-> version? version? (or/c -1 0 1))]
  [version=? (-> version? version? boolean?)]
  [version<? (-> version? version? boolean?)]
  [version>? (-> version? version? boolean?)]
  [version<=? (-> version? version? boolean?)]
  [version>=? (-> version? version? boolean?)]
  ;; version version -> boolean, D-007 exact: equality only
  [version-matches? (-> version? version? boolean?)]))

;; ---------------------------------------------------------------------------
;; Data and parsing

(struct version (text numbers))
;; text    : string?  the original text, printed verbatim
;; numbers : (or/c (listof exact-nonnegative-integer?) #f)  #f when label-only

;; string -> boolean, all chars ASCII digits, at least one
(define (all-digits? s)
  (and (> (string-length s) 0)
       (for/and ([c (in-string s)])
         (and (char<=? #\0 c) (char<=? c #\9)))))

;; string -> (or/c (listof exact-nonnegative-integer?) #f)
;; Dotted numerics like "2.9.1" or date-based "20250115.1432".
(define (parse-numbers s)
  (define parts (string-split s "." #:trim? #f))
  (and (not (string=? s ""))
       (andmap all-digits? parts)
       (map string->number parts)))

;; char -> boolean
(define (name-char? c)
  (or (char-alphabetic? c) (char-numeric? c)))

;; string -> boolean, plain labels like "main" (never "", never "1..2")
(define (valid-label? s)
  (and (> (string-length s) 0)
       (name-char? (string-ref s 0))
       (name-char? (string-ref s (sub1 (string-length s))))
       (for/and ([c (in-string s)])
         (or (name-char? c) (memv c '(#\. #\_ #\-))))
       (not (regexp-match? #rx"\\.\\." s))))

;; string -> version, bad input raises kind 'spec with the string
(define (string->version s)
  (cond [(parse-numbers s) => (lambda (ns) (version s ns))]
        [(valid-label? s) (version s #f)]
        [else (raise-pm-error 'spec 'string->version "invalid version"
                              #:fields `(("value" . ,s)))]))

;; version -> string, the original text verbatim
(define (version->string v)
  (version-text v))

;; ---------------------------------------------------------------------------
;; Ordering: numeric where both numeric (missing components count as 0,
;; so "1.0" == "1.0.0"); numeric sorts before labels; labels by string<?.

;; (listof nat) (listof nat) -> -1/0/1
(define (compare-numbers na nb)
  (cond [(and (null? na) (null? nb)) 0]
        [else
         (define a (if (null? na) 0 (car na)))
         (define b (if (null? nb) 0 (car nb)))
         (cond [(< a b) -1]
               [(> a b) 1]
               [else (compare-numbers (if (null? na) '() (cdr na))
                                      (if (null? nb) '() (cdr nb)))])]))

;; version version -> -1/0/1
(define (version-compare a b)
  (define na (version-numbers a))
  (define nb (version-numbers b))
  (cond [(and na nb) (compare-numbers na nb)]
        [(and (not na) (not nb))
         (cond [(string=? (version-text a) (version-text b)) 0]
               [(string<? (version-text a) (version-text b)) -1]
               [else 1])]
        [na -1]
        [else 1]))

;; version version -> boolean
(define (version=? a b) (zero? (version-compare a b)))
(define (version<? a b) (= (version-compare a b) -1))
(define (version>? a b) (= (version-compare a b) 1))
(define (version<=? a b) (not (= (version-compare a b) 1)))
(define (version>=? a b) (not (= (version-compare a b) -1)))

;; version version -> boolean, D-007 exact: equality only
(define (version-matches? constraint candidate)
  (version=? constraint candidate))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit)

  ;; Numeric compare is numeric: "1.10" > "1.9".
  (check-true (version>? (string->version "1.10") (string->version "1.9")))
  (check-true (version<? (string->version "2.9") (string->version "2.9.1")))
  (check-true (version>? (string->version "20250116.1")
                         (string->version "20250115.1432")))

  ;; "1.0" vs "1.0.0": recorded choice is equal (missing parts count as 0).
  (check-true (version=? (string->version "1.0") (string->version "1.0.0")))
  (check-equal? (version-compare (string->version "1.0")
                                 (string->version "1.0.0"))
                0)

  ;; Round-trips print the original text.
  (for ([s (in-list '("2.9.1" "20250115.1432" "main" "v1.2.3" "01.2"))])
    (check-equal? (version->string (string->version s)) s))

  ;; Labels match by equality only.
  (check-true (version-matches? (string->version "main")
                                (string->version "main")))
  (check-false (version-matches? (string->version "main")
                                 (string->version "dev")))

  ;; Hostile inputs raise kind 'spec with the offending string.
  (for ([s (in-list '("" "1..2" "-1" ".5" "1."))])
    (check-exn exn:fail:pm? (lambda () (string->version s))))
  (check-exn #rx"1\\.\\.2"
             (lambda () (string->version "1..2")))
  (check-pred spec-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (string->version "-1"))))
