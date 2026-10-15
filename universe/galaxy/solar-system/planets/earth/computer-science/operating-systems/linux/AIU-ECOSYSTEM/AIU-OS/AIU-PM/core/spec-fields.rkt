#lang racket/base
;; spec-fields.rkt -- the closed field table and the plumbing every
;; field reader shares: the located failure (D-4), the key list, the
;; field accessors, and the converters that turn one field's syntax
;; into plain data (no I/O).
;;
;; Split out of spec-read.rkt, which did four jobs in one file. This one
;; is the BASE of the split, so the dependency direction is one-way and
;; cannot cycle: spec-typos needs nothing, this needs spec-typos for
;; "did you mean", spec-source and spec-build-steps need this for
;; field-args and fail, and spec-read needs all three.
;;
;; The located failure lives here for the same reason: every other job
;; complains through it, and putting it in any one of them would make
;; that file sideways-dependent on its siblings for a five-line
;; function.

(require "errors.rkt"
         "git-url.rkt"
         "security.rkt"
         "version.rkt"
         "spec.rkt"
         "spec-typos.rkt")

(provide
 ;; syntax -> string, file:line:col of STX for messages
 loc-string
 ;; syntax string -> never returns (E-1, E-2, E-4)
 fail
 ;; (listof syntax) -> void, unknown keys and duplicates are errors (D-2)
 check-keys
 ;; (listof syntax) symbol -> (or/c syntax #f), the field form for KEY
 find-field
 ;; (listof syntax) symbol -> syntax, missing fields are errors
 need-field
 ;; syntax exact-integer -> (listof syntax), arity-checked value forms
 field-args
 ;; syntax -> version, bad input names the value at its location
 convert-version
 ;; syntax -> string, validated commit id or a located error
 convert-commit
 ;; syntax -> string, validated git URL or a located error
 convert-url
 ;; syntax -> package-name symbol or a located error
 convert-name)

;; ---------------------------------------------------------------------------
;; Locations (D-4: columns print +1, lines stay raw)

;; syntax -> string, file:line:col of STX for messages
(define (loc-string stx)
  (format "~a:~a:~a"
          (or (syntax-source stx) "?")
          (or (syntax-line stx) "?")
          (let ((c (syntax-column stx))) (if c (+ c 1) "?"))))

;; syntax string -> never returns (E-1, E-2, E-4)
(define (fail stx hint)
  (raise-pm-error 'spec 'read-spec "invalid declaration"
                  #:fields `(("at" . ,(loc-string stx)))
                  #:hint hint))

;; ---------------------------------------------------------------------------
;; Field table

;; Known single-form keys; when-clauses use the head symbol when.
;; Private on purpose: this file owns the vocabulary, and a caller
;; passes it to suggest-key rather than carrying a second copy.
(define known-keys
  '(format-version name version summary source deps build-deps build
                   install license homepage extends variants slot flags))

;; (listof syntax) -> void, unknown keys and duplicates are errors (D-2)
(define (check-keys forms)
  (define seen '())
  (for ([f (in-list forms)])
    (define parts (syntax->list f))
    (unless (and parts (pair? parts))
      (fail f "expected a (KEY ...) form"))
    (define head (syntax->datum (car parts)))
    (cond [(eq? head 'when) (void)]
          [(not (memq head known-keys))
           (fail (car parts) (format "unknown key '~a~a" head
                                     (if (symbol? head)
                                         (suggest-key known-keys head)
                                         "")))]
          [(memq head seen)
           (fail (car parts) (format "duplicate field '~a" head))]
          [else (set! seen (cons head seen))])))

;; (listof syntax) symbol -> (or/c syntax #f), the field form for KEY
(define (find-field forms key)
  (for/or ([f (in-list forms)])
    (define parts (syntax->list f))
    (and parts (pair? parts)
         (eq? (syntax->datum (car parts)) key)
         f)))

;; (listof syntax) symbol -> syntax, missing fields are errors
(define (need-field forms key top)
  (or (find-field forms key)
      (fail top (format "missing required field '~a" key))))

;; syntax exact-integer -> (listof syntax), arity-checked value forms
(define (field-args form n key)
  (define parts (cdr (syntax->list form)))
  (unless (= (length parts) n)
    (fail form (format "field '~a takes exactly ~a value" key n)))
  parts)

;; ---------------------------------------------------------------------------
;; Value converters (wrap sub-validator failures with srcloc)

;; syntax -> version, bad input names the value at its location
(define (convert-version stx)
  (with-handlers
      ([exn:fail:pm?
        (lambda (_) (fail stx (format "invalid version ~s"
                                      (syntax->datum stx))))])
    (define v (syntax->datum stx))
    (unless (string? v)
      (fail stx "version must be a string"))
    (string->version v)))

;; syntax -> string, validated commit id or a located error
(define (convert-commit stx)
  (define c (syntax->datum stx))
  ;; S-01: a declaration pins or it refuses.
  (unless (source-pinned? c)
    (fail stx (format "[source-trust] not a commit id ~s" c)))
  c)

;; syntax -> string, validated git URL or a located error
(define (convert-url stx)
  (define u (syntax->datum stx))
  (with-handlers
      ([exn:fail:pm?
        (lambda (e)
          (define reason
            (let ([cell (assoc "reason" (exn:fail:pm-fields e))])
              (if cell (cdr cell) "?")))
          (fail stx (format "[origin] rejected git URL ~s (~a" u reason)))])
    (unless (string? u)
      (fail stx "URL must be a string"))
    (check-git-url u)
    u))

;; syntax -> package-name symbol or a located error
(define (convert-name stx)
  (define n (syntax->datum stx))
  (unless (package-name? n)
    (fail stx (format "invalid package name ~s" n)))
  n)
