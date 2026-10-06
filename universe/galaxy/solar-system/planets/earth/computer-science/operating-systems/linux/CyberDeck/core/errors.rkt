#lang racket/base
;; errors.rkt -- the only module that defines exception types and formats messages.

(require racket/contract/base
         racket/string)

(provide
 (struct-out exn:fail:pm)
 (contract-out
  ;; The set of error kinds (E-3).
  [pm-kind/c contract?]
  ;; kind who message -> never returns (E-4, E-1, E-2)
  [raise-pm-error (->* (pm-kind/c symbol? string?)
                       (#:fields (listof (cons/c string? any/c))
                        #:hint (or/c string? #f)
                        #:cause (or/c exn? #f))
                       any)]
  ;; exn:fail:pm -> exit code per E-15 [PROPOSAL] (D-008 open)
  [pm-error-exit-code (-> exn:fail:pm? exact-nonnegative-integer?)]
  ;; exn:fail:syntax kind -> exn:fail:pm, for the spec-read boundary (D-4)
  [syntax-error->pm-error (->* (exn:fail:syntax? pm-kind/c)
                               (#:who symbol?)
                               exn:fail:pm?)]
  ;; One predicate per kind (E-3)
  [spec-error? (-> any/c boolean?)]
  [resolve-error? (-> any/c boolean?)]
  [fetch-error? (-> any/c boolean?)]
  [verify-error? (-> any/c boolean?)]
  [build-error? (-> any/c boolean?)]
  [install-error? (-> any/c boolean?)]
  [config-error? (-> any/c boolean?)]
  [internal-error? (-> any/c boolean?)]))

;; ---------------------------------------------------------------------------
;; Exception type and kind contract

;; contract : the set of error kinds (E-3)
(define pm-kind/c
  (or/c 'spec 'resolve 'fetch 'verify 'build 'install 'config 'internal))

(struct exn:fail:pm exn:fail (kind fields hint cause))
;; kind   : pm-kind/c                      which stage failed
;; fields : (Listof (Pairof String Any))   shown as "  field: value" lines
;; hint   : (U String #f)                  the NEXT line
;; cause  : (U Exn #f)                     wrapped lower-level exception (E-6)

;; ---------------------------------------------------------------------------
;; Raising and rendering (E-1, E-2, E-4)

;; symbol string fields hint cause -> string
;; Racket puts ';' after the message ONLY when continuation lines follow.
(define (render-message who message fields hint cause)
  (define tail
    (string-append
     (apply string-append
            (for/list ([f (in-list fields)])
              (format "\n  ~a: ~a" (car f) (cdr f))))
     (if cause (format "\n  cause: ~a" (exn-message cause)) "")
     (if hint (format "\n  hint: ~a" hint) "")))
  (if (string=? tail "")
      (format "~a: ~a" who message)
      (format "~a: ~a;~a" who message tail)))

;; pm-kind symbol string -> never returns (E-4)
(define (raise-pm-error kind who message
                        #:fields [fields '()] #:hint [hint #f] #:cause [cause #f])
  (raise (exn:fail:pm (render-message who message fields hint cause)
                       (current-continuation-marks)
                       kind fields hint cause)))

;; exn:fail:pm -> exit code per E-15 [PROPOSAL] (D-008 open).
;; 'config' and 'internal' are absent from E-15; mapped to 2 and 70 here.
(define (pm-error-exit-code e)
  (case (exn:fail:pm-kind e)
    [(spec) 3] [(resolve) 4] [(fetch) 5] [(verify) 6]
    [(build) 7] [(install) 8] [(config) 2] [(internal) 70]
    [else 70]))

;; any -> boolean, one predicate per kind (E-3)
(define (spec-error? x) (and (exn:fail:pm? x) (eq? (exn:fail:pm-kind x) 'spec)))
(define (resolve-error? x) (and (exn:fail:pm? x) (eq? (exn:fail:pm-kind x) 'resolve)))
(define (fetch-error? x) (and (exn:fail:pm? x) (eq? (exn:fail:pm-kind x) 'fetch)))
(define (verify-error? x) (and (exn:fail:pm? x) (eq? (exn:fail:pm-kind x) 'verify)))
(define (build-error? x) (and (exn:fail:pm? x) (eq? (exn:fail:pm-kind x) 'build)))
(define (install-error? x) (and (exn:fail:pm? x) (eq? (exn:fail:pm-kind x) 'install)))
(define (config-error? x) (and (exn:fail:pm? x) (eq? (exn:fail:pm-kind x) 'config)))
(define (internal-error? x) (and (exn:fail:pm? x) (eq? (exn:fail:pm-kind x) 'internal)))

;; ---------------------------------------------------------------------------
;; Wrapping syntax-parse failures (D-4, E-6)

;; exn:fail:syntax pm-kind -> exn:fail:pm
;; Wrap a declaration failure for the spec-read boundary: srcloc in fields,
;; original exn in cause, so ui only handles one type.
(define (syntax-error->pm-error e kind #:who [who 'read-spec])
  ;; Racket columns are 0-based; humans get +1 (lines already 1-based).
  (define (location-string x)
    (format "~a:~a:~a"
            (or (syntax-source x) "?")
            (or (syntax-line x) "?")
            (let ((c (syntax-column x))) (if c (+ c 1) "?"))))
  (define locs
    (for/list ([x (in-list (exn:fail:syntax-exprs e))])
      (location-string x)))
  (define fields `(("at" . ,(string-join locs ", "))))
  (exn:fail:pm (render-message who "invalid declaration" fields #f e)
               (current-continuation-marks)
               kind fields #f e))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           syntax/parse)

  ;; Bare message carries no ';' (item 3).
  (check-equal?
   (with-handlers ([exn:fail:pm? exn-message])
     (raise-pm-error 'fetch 'fetch-source "download failed"))
   "fetch-source: download failed")

  ;; Full shape, golden sample for docs/ERRORS.org.
  (check-equal?
   (with-handlers ([exn:fail:pm? exn-message])
     (raise-pm-error 'fetch 'fetch-source "download failed"
                     #:fields '(("url" . "https://x.test/a.tgz"))
                     #:hint "check the URL"
                     #:cause (exn:fail "net down"
                                       (current-continuation-marks))))
   (string-join '("fetch-source: download failed;"
                  "  url: https://x.test/a.tgz"
                  "  cause: net down"
                  "  hint: check the URL")
                "\n"))

  ;; Kind typos fail at the boundary (pm-kind/c as a value rejects).
  ;; NOTE: module+ test sees local bindings uncontracted, so the check
  ;; below exercises the contract value directly; ui.rkt's tests exercise
  ;; the real cross-module boundary.
  (check-exn exn:fail:contract?
             (lambda ()
               ((contract pm-kind/c (lambda (x) x) 'test 'test) 'fetsh)))

  ;; Exit codes per E-15 [PROPOSAL], incl. the config/internal mapping.
  (define (code-for kind)
    (pm-error-exit-code
     (exn:fail:pm "m" (current-continuation-marks) kind '() #f #f)))
  (check-equal? (map code-for '(spec resolve fetch verify build install config internal))
                '(3 4 5 6 7 8 2 70))

  ;; Predicates sort by kind.
  (define fetch-exn
    (exn:fail:pm "m" (current-continuation-marks) 'fetch '() #f #f))
  (check-true (fetch-error? fetch-exn))
  (check-false (fetch-error? (exn:fail "plain" (current-continuation-marks))))
  (check-false (fetch-error? "not-an-exn"))

  ;; Syntax failures wrap with srcloc fields and the original cause.
  (define in (open-input-string "(42 oops)"))
  (port-count-lines! in)
  (define bad-syntax (read-syntax "spec.rktd" in))
  (define wrapped
    (with-handlers ([exn:fail:syntax? (lambda (e) (syntax-error->pm-error e 'spec))])
      (syntax-parse bad-syntax [({~datum define} _.id) "matched"])))
  (check-pred spec-error? wrapped)
  (check-equal? (exn:fail:pm-kind wrapped) 'spec)
  (check-equal? (exn:fail:pm-fields wrapped) '(("at" . "spec.rktd:1:2")))
  (check-pred exn:fail:syntax? (exn:fail:pm-cause wrapped))

  ;; Leading spaces move the column; columns count from 1.
  (define spaced-in (open-input-string "  (42 oops)"))
  (port-count-lines! spaced-in)
  (define spaced-syntax (read-syntax "spec.rktd" spaced-in))
  (define spaced-wrapped
    (with-handlers ([exn:fail:syntax? (lambda (e) (syntax-error->pm-error e 'spec))])
      (syntax-parse spaced-syntax [({~datum define} _.id) "matched"])))
  (check-equal? (exn:fail:pm-fields spaced-wrapped) '(("at" . "spec.rktd:1:4"))))
