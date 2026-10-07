#lang racket/base
;; resolve.rkt -- exact-version dependency resolution. Pure, no I/O.
;; Deterministic ordered walk: dependencies first, first listing wins,
;; shared deps emitted once. Versions match by equality only (D-007).

(require racket/contract/base
         racket/string
         "errors.rkt"
         "version.rkt"
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
(module+ test
  (require rackunit
           "errors.rkt"
           "version.rkt"
           "spec.rkt")

  ;; spec symbol string (listof (list symbol string)) -> spec
  (define (test-spec name ver deps)
    (spec name (string->version ver) "test package"
          (source "https://example.org/x.git"
                  "9edb3f66fd807b096b48283debdcddccfea34bad")
          (map (lambda (d) (dep (car d) (string->version (cadr d))))
               deps)
          (list (build-step 'byte-compile '()))
          (install-spec 'emacs '())
          'mit "https://example.org" #f '() '()))

  ;; Linear chain resolves dependency-first.
  (define chain-c (test-spec 'c "1.0" '()))
  (define chain-b (test-spec 'b "1.0" '((c "1.0"))))
  (define chain-a (test-spec 'a "1.0" '((b "1.0"))))
  (check-equal? (map spec-name (resolve (list chain-a chain-b chain-c)
                                        (list chain-a)))
                '(c b a))

  ;; Diamonds emit the shared dep once, first encounter wins.
  (define dia-a (test-spec 'a "1.0" '()))
  (define dia-b (test-spec 'b "1.0" '((a "1.0"))))
  (define dia-c (test-spec 'c "1.0" '((a "1.0"))))
  (define dia-d (test-spec 'd "1.0" '((b "1.0") (c "1.0"))))
  (check-equal? (map spec-name (resolve (list dia-d dia-c dia-b dia-a)
                                        (list dia-d)))
                '(a b c d))

  ;; Empty roots resolve empty.
  (check-equal? (resolve (list chain-a) '()) '())

  ;; Exact message for a missing dep (design-doc sample).
  (define pkg-a (test-spec 'pkg-alpha "4.0.0" '((pkg-beta "1.0.0"))))
  (check-equal?
   (with-handlers ([exn:fail:pm? exn-message])
     (resolve (list pkg-a) (list pkg-a))
     "NO-ERROR")
   (string-append "resolve: unsatisfiable dependency;\n"
                  "  package: pkg-alpha 4.0.0\n"
                  "  dep: pkg-beta 1.0.0\n"
                  "  hint: no spec provides pkg-beta 1.0.0"))

  ;; Equality only: pkg-beta 2.0 does not satisfy 1.0.
  (define compat-2 (test-spec 'pkg-beta "2.0" '()))
  (check-pred resolve-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (resolve (list pkg-a compat-2) (list pkg-a))
                'no-error))

  ;; Cycles name the chain and raise kind 'resolve.
  (define cyc-a (test-spec 'a "1.0" '((b "1.0"))))
  (define cyc-b (test-spec 'b "1.0" '((a "1.0"))))
  (define cycle-error
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (resolve (list cyc-a cyc-b) (list cyc-a))
      'no-error))
  (check-pred resolve-error? cycle-error)
  (check-regexp-match #rx"dependency cycle" (exn-message cycle-error))
  (check-regexp-match #rx"a 1.0" (exn-message cycle-error)))
