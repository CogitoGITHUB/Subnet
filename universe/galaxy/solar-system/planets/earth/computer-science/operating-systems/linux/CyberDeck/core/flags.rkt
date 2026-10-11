#lang racket/base
;; flags.rkt -- USE-style flag resolution (D-022). Pure, no I/O.
;; A package declares named flags with defaults (spec flags field, E-02);
;; one config file sets them globally and per package. Precedence is fixed:
;; spec default < global < per-package. Anything set but not declared is an
;; error, and so are violated conflicts, unsatisfied requires, and
;; non-boolean values (booleans are the only declared type today; a new
;; type means a new flag-spec shape plus a case here). Malformed
;; declarations never reach this module: the flag-spec guard rejects them
;; with kind 'spec at the boundary (E-02).

(require racket/contract/base
         racket/list
         "errors.rkt"
         "spec.rkt")

(provide
 (contract-out
  ;; spec (listof (cons symbol boolean)) (listof (cons symbol boolean))
  ;; -> (listof (cons symbol boolean)), resolved value per declared flag.
  ;; Configs are plain alists so callers (and tests) build them by hand;
  ;; file reading arrives with the config file, not here.
  [resolve-flags
   (-> spec? (listof (cons/c symbol? boolean?))
       (listof (cons/c symbol? boolean?))
       (listof (cons/c symbol? boolean?)))]))

;; ---------------------------------------------------------------------------
;; Resolution (D-022: spec default < global < per-package)

;; (listof flag-spec) symbol (listof cons) (listof cons) -> boolean,
;; the winning value: per-package first, then global, then the default.
;; assoc returns a pair or #f, so presence is tested with pair?, never
;; with the value: a set #f is a real answer, not a miss (treating #f as
;; missing silently restored the default and broke both disables and the
;; requires check built on them).
(define (winning-value declared name global per-package)
  (define hit-p (assoc name per-package))
  (define hit-g (assoc name global))
  (cond [(pair? hit-p) (cdr hit-p)]
        [(pair? hit-g) (cdr hit-g)]
        [else
         (flag-spec-default
          (findf (lambda (f) (eq? (flag-spec-name f) name))
                 declared))]))

;; (listof flag-spec) (listof cons) string -> void, every set name declared
(define (check-known declared cfg whose)
  (define names (map flag-spec-name declared))
  (for ([pair (in-list cfg)])
    (unless (memq (car pair) names)
      (raise-pm-error 'config 'resolve-flags
                      (format "unknown flag for ~a" whose)
                      #:fields `(("flag" . ,(format "~a" (car pair))))))))

;; (listof flag-spec) (listof cons) -> void, booleans only (sole type today)
(define (check-types declared cfg whose)
  (for ([pair (in-list cfg)])
    (when (and (memq (car pair) (map flag-spec-name declared))
               (not (boolean? (cdr pair))))
      (raise-pm-error 'config 'resolve-flags
                      (format "flag value for ~a must be #t or #f" whose)
                      #:fields `(("flag" . ,(format "~a" (car pair)))
                                ("value" . ,(format "~s" (cdr pair))))))))

;; spec (listof cons) (listof cons) -> (listof cons), full coverage:
;; every declared flag resolved, defaults filled for anything unset
(define (resolve-flags specification global per-package)
  (define declared (spec-flags specification))
  (check-known declared global "global config")
  (check-known declared per-package "per-package config")
  (check-types declared global "global config")
  (check-types declared per-package "per-package config")
  (define resolved
    (for/list ([f (in-list declared)])
      (cons (flag-spec-name f)
            (winning-value declared (flag-spec-name f) global per-package))))
  (check-conflicts declared resolved)
  (check-requires declared resolved)
  resolved)

;; (listof flag-spec) (listof cons) -> void, no conflicts pair both on
(define (check-conflicts declared resolved)
  (define (on? name)
    (cdr (or (assoc name resolved) (cons name #f))))
  (for ([f (in-list declared)]
        #:when (on? (flag-spec-name f)))
    (for ([other (in-list (flag-spec-conflicts f))]
          #:when (on? other))
      (raise-pm-error 'config 'resolve-flags "conflicting flags both set"
                      #:fields `(("flags" . ,(format "~a ~a"
                                                    (flag-spec-name f)
                                                    other)))))))

;; (listof flag-spec) (listof cons) -> void, every require on with its flag
(define (check-requires declared resolved)
  (define (on? name)
    (cdr (or (assoc name resolved) (cons name #f))))
  (for ([f (in-list declared)]
        #:when (on? (flag-spec-name f)))
    (for ([need (in-list (flag-spec-requires f))]
          #:unless (on? need))
      (raise-pm-error 'config 'resolve-flags "flag requires an unset flag"
                      #:fields `(("flag" . ,(format "~a" (flag-spec-name f)))
                                ("needs" . ,(format "~a" need)))))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           "errors.rkt"
           "version.rkt")

  ;; Synthetic package declaring three flags with defaults (T-10).
  (define demo-spec
    (spec 'pkg-alpha (string->version "1.0") "demo"
          (source "https://example.org/d.git"
                  "9edb3f66fd807b096b48283debdcddccfea34bad")
          '() '()
          (list (build-step 'copy '("a" "b")))
          (install-spec 'prefix '((bin "b")))
          'mit "https://example.org" #f '() '()
          'default
          (list (flag-spec 'gui #t "Graphical interface" '(minimal) '(x11))
                (flag-spec 'minimal #f "No extras" '() '())
                (flag-spec 'x11 #t "X11 backend" '() '()))))

  (define (config-kind thunk)
    (with-handlers ([exn:fail:pm? exn:fail:pm-kind])
      (thunk)
      #f))

  ;; Precedence, one test per level: default, then global, then per-package.
  (check-equal? (resolve-flags demo-spec '() '())
                '((gui . #t) (minimal . #f) (x11 . #t)))
  (check-equal? (resolve-flags demo-spec '((gui . #f)) '())
                '((gui . #f) (minimal . #f) (x11 . #t)))
  (check-equal? (resolve-flags demo-spec '((gui . #f)) '((gui . #t)))
                '((gui . #t) (minimal . #f) (x11 . #t)))

  ;; Unknown names fail on either side, kind 'config.
  (check-eq? (config-kind
              (lambda () (resolve-flags demo-spec '((nope . #t)) '())))
             'config)
  (check-eq? (config-kind
              (lambda () (resolve-flags demo-spec '() '((nope . #t)))))
             'config)

  ;; gui conflicts with minimal: both on is an error.
  (check-eq? (config-kind
              (lambda ()
                (resolve-flags demo-spec '((minimal . #t)) '())))
             'config)

  ;; gui requires x11: gui on with x11 off is an error.
  (check-eq? (config-kind
              (lambda ()
                (resolve-flags demo-spec '((x11 . #f)) '())))
             'config)

  ;; Only booleans are declared types today.
  (check-eq? (config-kind
              (lambda ()
                (resolve-flags demo-spec '((gui . "yes")) '())))
             'config))
