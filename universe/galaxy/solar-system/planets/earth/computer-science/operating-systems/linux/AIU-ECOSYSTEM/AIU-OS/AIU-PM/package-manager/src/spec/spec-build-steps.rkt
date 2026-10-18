#lang racket/base
;; spec-build-steps.rkt -- how a package is built and where it lands:
;; the closed step vocabulary, each step's required keys, and the
;; (prefix ...) install forms. No I/O; syntax arrives already read.
;;
;; Split out of spec-read.rkt, which did four jobs in one file. This is
;; the only file that owns the step list and the step-key table, which
;; is the point: core/ecosystem.rkt (E-25) and backends/build.rkt share
;; this answer instead of keeping a second copy that could drift. The
;; direction is downward only -- field-args and fail come from
;; spec-fields.rkt, the base of the split -- so this file does not
;; depend sideways on spec-source.rkt for anything.

(require racket/string
         "spec.rkt"
         "../security/security.rkt"
         "spec-fields.rkt")

(provide
 ;; symbol -> boolean, closed build vocabulary membership
 valid-build-step?
 ;; symbol -> (listof keyword), shared step-argument contract
 step-required-keys
 ;; syntax -> (listof build-step), (steps STEP ...) with any step count
 read-build
 ;; syntax -> install-spec, (prefix FORM ...) with kind-checked forms
 read-install)

;; ---------------------------------------------------------------------------
;; The closed step vocabulary

;; Closed build vocabulary (SPEC-NEUTRAL.org section 2), alphabetical:
;; the unknown-step hint prints this list verbatim.
(define valid-steps
  '(cmake-build cmake-configure cmake-install configure copy make
                make-info cargo run))

;; symbol -> boolean, closed build vocabulary membership
(define (valid-build-step? step)
  (if (memq step valid-steps) #t #f))

;; symbol -> (listof keyword) or #f, required keys for typed steps.
;; Plain-data steps (configure cargo make-info copy) take any data args.
(define (step-required-keys step)
  (case step
    [(make) '(#:targets)]
    [(cmake-configure) '(#:srcdir #:builddir)]
    [(cmake-build) '(#:builddir)]
    [(cmake-install) '(#:builddir)]
    [(run) '(#:argv)]
    [else '()]))

;; ---------------------------------------------------------------------------
;; Build steps

;; syntax -> (listof build-step), (steps STEP ...) with any step count
(define (read-build form)
  (define steps-form (car (field-args form 1 'build)))
  (define wrap (syntax->list steps-form))
  (define head-ok?
    (and wrap (pair? wrap) (eq? (syntax->datum (car wrap)) 'steps)))
  (if (not head-ok?)
      (fail steps-form "build must be (steps STEP ...)")
      (for/list ([s (in-list (cdr wrap))])
        (read-one-step s))))

;; syntax -> build-step, one (NAME ARG ...) datum
(define (read-one-step s)
  (define parts (syntax->list s))
  (define shape-ok?
    (and parts (pair? parts) (symbol? (syntax->datum (car parts)))))
  (if (not shape-ok?)
      (fail s "step must be (NAME ARG ...)")
      (read-named-step s (syntax->datum (car parts)))))

;; syntax symbol -> build-step, vocabulary and required keys
(define (read-named-step s step-name)
  (unless (memq step-name valid-steps)
    (fail s (format "unknown build step '~a (valid: ~a)" step-name
                    (string-join (map symbol->string valid-steps) " "))))
  (read-step-args s step-name (step-required-keys step-name)))

;; syntax symbol (listof keyword) -> build-step, required keys present
(define (read-step-args s step-name need)
  (define data (map syntax->datum (cdr (syntax->list s))))
  (for ([k (in-list need)])
    (unless (member k data)
      (fail s (format "step '~a needs ~a" step-name k))))
  (build-step step-name data))

;; ---------------------------------------------------------------------------
;; Install forms

;; syntax -> install-spec, (prefix FORM ...) with kind-checked forms
(define (read-install form)
  (define install-form (car (field-args form 1 'install)))
  (define inner (syntax->list install-form))
  (define head-ok?
    (and inner (pair? inner)
         (eq? (syntax->datum (car inner)) 'prefix)))
  (if (not head-ok?)
      (fail install-form "install must be (prefix ...)")
      (read-install-forms install-form (cdr inner))))

;; string -> boolean, DST stays inside the prefix (no absolute, no ..)
(define (prefix-confined? p)
  (and (string? p)
       (> (string-length p) 0)
       (not (string-prefix? p "/"))
       (not (member ".." (string-split p "/")))))

;; syntax string -> string, confined DST or a located error
(define (confine-dst stx p)
  (unless (prefix-confined? p)
    (fail stx (format "[~a] install path '~a escapes the prefix"
                      (security-rule-id rule-path-escape) p)
          #:rule rule-path-escape))
  p)

;; syntax (listof syntax) -> install-spec, one check form at most
(define (read-install-forms form forms)
  (define seen-check? #f)
  (define datums
    (for/list ([f (in-list forms)])
      (define parts (syntax->list f))
      (unless (and parts (pair? parts)
                   (symbol? (syntax->datum (car parts))))
        (fail f "install forms must be a list of lists"))
      (define head (syntax->datum (car parts)))
      (define args (map syntax->datum (cdr parts)))
      (case head
        [(bin lib include share man libexec)
         (unless (and (<= 1 (length args) 2)
                      (andmap string? args))
           (fail f "install kind takes one or two paths"))
         (confine-dst f (car (reverse args)))]
        [(copy-tree symlink)
         (unless (and (= (length args) 2) (andmap string? args))
           (fail f "install kind takes two paths"))
         (confine-dst f (if (eq? head 'copy-tree)
                            (cadr args)
                            (car args)))
         (when (eq? head 'symlink)
           (confine-dst f (cadr args)))]
        [(mode)
         (unless (and (= (length args) 2)
                      (string? (car args))
                      (exact-integer? (cadr args)))
           (fail f "mode takes a path and an exact integer"))
         (confine-dst f (car args))
         (unless (install-mode-allowed? (cadr args))
           (fail f (format "[~a] mode ~a refused; pm writes only 755 and 644"
                           (security-rule-id rule-install-mode)
                           (cadr args))
                 #:rule rule-install-mode))]
        [(check)
         (when seen-check?
           (fail f "only one check form per install"))
         (set! seen-check? #t)
         (unless (and (>= (length args) 1) (andmap string? args))
           (fail f "check takes a program and args"))
         (void)]
        [else (fail (car (syntax->list f))
                    (format "unknown install form '~a" head))])
      (syntax->datum f)))
  (install-spec 'prefix datums))
