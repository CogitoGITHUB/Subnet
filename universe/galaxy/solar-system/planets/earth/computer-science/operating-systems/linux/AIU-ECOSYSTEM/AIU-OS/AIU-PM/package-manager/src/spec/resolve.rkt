#lang racket/base
;; resolve.rkt -- exact-version dependency resolution. Pure, no I/O.
;; Deterministic ordered walk: dependencies first, first listing wins,
;; shared deps emitted once. Versions match by equality only (D-007).

(require racket/contract/base
         racket/string
         "../errors/error-type.rkt"
         "./version.rkt"
         "spec.rkt")

(provide
 (contract-out
  ;; (listof spec) (listof spec) -> (listof spec)
  ;; available package set plus roots gives dependency-first order
  [resolve (-> (listof spec?) (listof spec?) (listof spec?))]))

;; ---------------------------------------------------------------------------
;; Lookup

;; spec -> (list symbol string), identity for dedupe and cycle reports
(define (spec-key s)
  (list (spec-name s) (version->string (spec-version s))))

;; spec -> string, "name version" for messages
(define (spec-label s)
  (string-append (symbol->string (spec-name s))
                 " "
                 (version->string (spec-version s))))

;; dep -> string, "name version" for messages
(define (dep-label d)
  (string-append (symbol->string (dep-name d))
                 " "
                 (version->string (dep-version d))))

;; (listof spec) symbol version -> (or/c spec #f)
(define (find-provider available name ver)
  (for/or ([s (in-list available)])
    (and (eq? (spec-name s) name)
         (version-matches? ver (spec-version s))
         s)))

;; (listof spec) spec dep -> spec, missing providers raise kind 'resolve
(define (require-dep available dependent d)
  (define found (find-provider available (dep-name d) (dep-version d)))
  (if found
      found
      (raise-pm-error 'resolve 'resolve "unsatisfiable dependency"
                      #:fields `(("package" . ,(spec-label dependent))
                                 ("dep" . ,(dep-label d)))
                      #:hint (string-append "no spec provides "
                                            (dep-label d)))))

;; ---------------------------------------------------------------------------
;; Ordered walk

;; (listof spec) (listof spec) -> (listof spec)
(define (resolve available roots)
  (define done (make-hash))
  (define visiting '())
  (define ordered '())
  (define (visit s)
    (define key (spec-key s))
    (cond [(hash-has-key? done key) (void)]
          [(member key visiting)
           (raise-pm-error
            'resolve 'resolve "dependency cycle"
            #:fields `(("chain" . ,(string-join
                                    (map (lambda (k)
                                           (string-append
                                            (symbol->string (car k))
                                            " "
                                            (cadr k)))
                                         (reverse (cons key visiting)))
                                    " -> "))))]
          [else
           (set! visiting (cons key visiting))
           (for ([d (in-list (spec-deps s))])
             (visit (require-dep available s d)))
           (set! visiting (cdr visiting))
           (hash-set! done key s)
           (set! ordered (cons s ordered))]))
  (for ([r (in-list roots)])
    (visit r))
  (reverse ordered))

;; ---------------------------------------------------------------------------
