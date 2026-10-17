#lang racket/base
;; spec-read.rkt -- read and validate .rktd spec files. No syntax/parse
;; at runtime (D-014): a hand-written table-driven validator walks the
;; read-syntax objects so every error carries file:line:col (D-3, D-4).
;;
;; This file is the ENTRY POINT and the facade. It used to do four jobs
;; at once; each job now lives in one file of its own, and the split
;; runs strictly downward so nothing can cycle:
;;
;;   spec-typos.rkt       edit distance, "did you mean"
;;   spec-fields.rkt      the located failure, the key table, converters
;;   spec-source.rkt      the git pin and the dependency lists
;;   spec-build-steps.rkt the step vocabulary and install forms
;;
;; read-spec-file stays here because it is the composition of all four:
;; it reads every field in order and hands each one to the parser that
;; owns it. It also owns the fields nobody else wanted -- format-version,
;; extends, slot, flags, variants, whens -- because those are read
;; straight into the spec struct and are not a job of their own.
;;
;; The provide below is the public promise and has not changed: ten
;; files require this module and three bindings are all they use. The
;; contracts stay HERE, on the facade, so blame still lands on the
;; caller of read-spec-file and not on an intermediate parser.

(require racket/contract/base
         racket/list
         racket/port
         racket/runtime-path
         "../errors/error-type.rkt"
         "spec.rkt"
         "spec-typos.rkt"
         "spec-fields.rkt"
         "spec-source.rkt"
         "spec-build-steps.rkt")

(provide
 (contract-out
  ;; path-string -> spec, bad input raises kind 'spec with srcloc
  [read-spec-file (-> path-string? spec?)]
  ;; symbol -> boolean, closed build vocabulary membership (E-25 shares
  ;; it with ecosystem files so no second vocabulary can drift)
  [valid-build-step? (-> symbol? boolean?)]
  ;; symbol -> required keywords, shared step-argument contract
  [step-required-keys (-> symbol? (listof keyword?))]))

;; ---------------------------------------------------------------------------
;; Reading (D-3)

;; 1MB cap like the foundation sketch; unreadable without code execution.
(define max-spec-bytes 1000000)

;; path-string -> syntax, one datum safely with source locations
(define (read-one path)
  (call-with-input-file path
    (lambda (in)
      (define limited (make-limited-input-port in max-spec-bytes #f))
      (port-count-lines! limited)
      (parameterize ([read-accept-reader #f]
                     [read-accept-lang #f]
                     [read-accept-compiled #f])
        (with-handlers
            ([exn:fail:read?
              (lambda (e)
                (raise-pm-error 'spec 'read-spec "cannot read declaration"
                                #:fields `(("file" . ,(path-string path)))
                                #:cause e))])
          (define first-datum (read-syntax path limited))
          (cond [(eof-object? first-datum)
                 (raise-pm-error 'spec 'read-spec "empty declaration"
                                 #:fields `(("file" . ,(path-string path))))]
                [(eof-object? (read-syntax path limited)) first-datum]
                [else
                 (raise-pm-error 'spec 'read-spec "trailing data"
                                 #:fields `(("file" . ,(path-string path)))
                                 #:hint "one (spec ...) form per file")]))))))

;; path-string -> string, for fields (paths and strings both allowed in)
(define (path-string p)
  (if (path? p) (path->string p) p))

;; ---------------------------------------------------------------------------
;; The fields this file reads itself: everything that goes straight
;; into the spec struct. source/deps/build come from spec-source.rkt and
;; spec-build-steps.rkt; the rest is here.

;; syntax -> exact-integer 2
(define (read-format-version form)
  (define (v) (car (field-args form 1 'format-version)))
  (define n (syntax->datum (v)))
  (unless (and (exact-integer? n) (= n 2))
    (fail (v) (format "unsupported format-version ~a (neutral spec needs 2; see ~a)"
                      n "docs/SPEC-NEUTRAL.org section 9")))
  n)

;; any -> boolean, true for syntax holding a list
(define (syntax-list? x)
  (if (and (syntax? x) (syntax->list x)) #t #f))

;; syntax -> (or/c symbol #f)
(define (read-extends form)
  (define n (syntax->datum (car (field-args form 1 'extends))))
  (unless (or (eq? n #f) (package-name? n))
    (fail (car (field-args form 1 'extends))
          (format "extends must be a name or #f, got ~s" n)))
  n)

;; syntax -> symbol, the version stream (D-023); one (slot NAME) per spec,
;; a second is the generic "duplicate field" in check-keys
(define (read-slot form)
  (define n (syntax->datum (car (field-args form 1 'slot))))
  (unless (slot-name? n)
    (fail (car (field-args form 1 'slot))
          (format "slot must be a stream name, got ~s" n)))
  n)

;; syntax -> (listof flag-spec), USE-style declarations (D-022); one
;; wrapped list like deps ((f ...) (...)), so (flags ()) reads as none
(define (read-flags form)
  (define items (syntax->list (car (field-args form 1 'flags))))
  (unless (list? items)
    (fail (car (field-args form 1 'flags)) "flags must be a list"))
  (define seen '())
  (for/list ([item (in-list items)])
    (define fs (read-one-flag item seen))
    (set! seen (cons (flag-spec-name fs) seen))
    fs))

;; syntax (listof symbol) -> flag-spec, one (NAME #:default BOOL #:doc STR
;; [#:conflicts (N ...)] [#:requires (N ...)]); every complaint names the
;; exact subform, so the srcloc points at the culprit, not the file
(define (read-one-flag item seen-before)
  (define parts (syntax->list item))
  (unless (and parts (pair? parts) (symbol? (syntax->datum (car parts))))
    (fail item "flag must be (NAME #:default BOOL #:doc STR ...)"))
  (define name (syntax->datum (car parts)))
  (define name-stx (car parts))
  (unless (package-name? name)
    (fail name-stx (format "bad flag name ~s" name)))
  (when (memq name seen-before)
    (fail name-stx (format "duplicate flag '~a" name)))
  (define kvs (cdr parts))
  (unless (even? (length kvs))
    (fail item (format "flag '~a needs #:key value pairs" name)))
  ;; keys are every other element starting at the first: NAME #:k v #:k v
  (define keys
    (for/list ([i (in-range 0 (length kvs) 2)])
      (syntax->datum (list-ref kvs i))))
  (define (opt key)
    (let loop ([rest kvs])
      (cond [(null? rest) #f]
            [(eq? (syntax->datum (car rest)) key) (cadr rest)]
            [else (loop (cddr rest))])))
  (for ([k (in-list keys)])
    (unless (memq k '(#:default #:doc #:conflicts #:requires))
      (fail item (format "flag '~a has unknown key '~a" name k))))
  (when (> (length (filter (lambda (k) (eq? k '#:default)) keys)) 1)
    (fail item (format "flag '~a repeats #:default" name)))
  (when (> (length (filter (lambda (k) (eq? k '#:doc)) keys)) 1)
    (fail item (format "flag '~a repeats #:doc" name)))
  (define (req key what)
    (define v (opt key))
    (unless v
      (fail item (format "flag '~a needs ~a" name what)))
    v)
  (define default-stx (req '#:default "#:default BOOL"))
  (define default (syntax->datum default-stx))
  (unless (boolean? default)
    (fail default-stx (format "flag '~a #:default must be #t or #f" name)))
  (define doc-stx (req '#:doc "#:doc STR"))
  (define doc (syntax->datum doc-stx))
  (unless (and (string? doc) (> (string-length doc) 0))
    (fail doc-stx (format "flag '~a #:doc must be a nonempty string" name)))
  (define (name-list key)
    (define v (opt key))
    (if (not v)
        '()
        (let ((ns (syntax->datum v)))
          (unless (and (list? ns) (andmap package-name? ns))
            (fail v (format "flag '~a ~a must be flag names" name key)))
          ns)))
  (flag-spec name default doc
             (name-list '#:conflicts) (name-list '#:requires)))

;; syntax -> (listof variant-spec), overrides exclude name/extends/variants
(define (read-variants form)
  (define (v) (car (field-args form 1 'variants)))
  (define items (syntax->list (v)))
  (if (not items)
      (fail (v) "variants must be a list")
      (for/list ([item (in-list items)])
        (read-one-variant item))))

;; syntax -> variant-spec, one (NAME FIELD ...) datum
(define (read-one-variant item)
  (define parts (syntax->list item))
  (define shape-ok?
    (and parts (pair? parts) (symbol? (syntax->datum (car parts)))))
  (if (not shape-ok?)
      (fail item "variant must be (NAME FIELD ...)")
      (read-variant-fields item
                            (syntax->datum (car parts))
                            (cdr parts))))

;; syntax symbol (listof syntax) -> variant-spec, checked override heads
(define (read-variant-fields item name overrides)
  (define verdict
    (for/or ([o (in-list overrides)])
      (variant-override-verdict o)))
  (if (string? verdict)
      (fail item verdict)
      (variant-spec name (map syntax->datum overrides))))

;; syntax -> (or/c string #f), complaint about one override or #f
(define (variant-override-verdict o)
  (define oparts (syntax->list o))
  (define head (and oparts (pair? oparts)
                    (syntax->datum (car oparts))))
  (cond [(memq head '(name extends variants))
         (format "variant must not override '~a" head)]
        [(memq head '(version summary source deps build-deps build
                      install license homepage when slot flags))
         #f]
        [else (format "unknown key '~a" head)]))

;; syntax (listof symbol) -> when-spec, conds come from the fixed table.
;; A (flag NAME) cond names a USE flag the spec must declare (D-022);
;; naming anything else is kind 'spec on the NAME, not the file.
(define (read-when form known-flags)
  (define parts (syntax->list form))
  (unless (>= (length parts) 2)
    (fail form "when needs (when COND FIELD ...)"))
  (define cond-parts (syntax->list (cadr parts)))
  (unless (and cond-parts (pair? cond-parts))
    (fail (cadr parts) "condition must be a list"))
  (define head (syntax->datum (car cond-parts)))
  (case head
    [(platform)
     (unless (and (= (length cond-parts) 2)
                  (memq (syntax->datum (cadr cond-parts))
                        '(linux darwin windows)))
       (fail (cadr parts) "platform is (platform linux|darwin|windows)"))]
    [(feature)
     (unless (= (length cond-parts) 2)
       (fail (cadr parts) "feature cond is (feature NAME)"))]
    [(flag)
     (unless (= (length cond-parts) 2)
       (fail (cadr parts) "flag cond is (flag NAME)"))
     (define named (syntax->datum (cadr cond-parts)))
     (unless (memq named known-flags)
       (fail (cadr parts)
             (format "unknown flag '~a" named)))]
    [else (fail (car cond-parts)
                (format "unknown condition '~a" head))])
  (when-spec (syntax->datum (cadr parts))
             (map syntax->datum (cddr parts))))

;; ---------------------------------------------------------------------------
;; Entry point

;; path-string -> spec (D-1: one immutable struct from one data file)
(define (read-spec-file path)
  (define top (read-one path))
  (define forms (syntax->list top))
  (unless (and forms (pair? forms)
               (eq? (syntax->datum (car forms)) 'spec))
    (fail top "expected (spec ...)"))
  (define body (cdr forms))
  (check-keys body)
  (define (req key) (need-field body key top))
  (define (one form) (car (field-args form 1 (syntax->datum
                                              (car (syntax->list form))))))
  (read-format-version (req 'format-version))
  (define name-value (convert-name (one (req 'name))))
  (define version-value (convert-version (one (req 'version))))
  (define summary-value (syntax->datum (one (req 'summary))))
  (unless (string? summary-value)
    (fail (one (req 'summary)) "summary must be a string"))
  (define source-value (read-source (req 'source)))
  (define extend-form (find-field body 'extends))
  (define variant-form (find-field body 'variants))
  ;; Flags read before whens: a (flag NAME) cond is checked against the
  ;; names declared here, so use before declaration cannot slip through.
  (define flags-value
    (if (find-field body 'flags)
        (read-flags (req 'flags))
        '()))
  (define known-flags (map flag-spec-name flags-value))
  (define slot-value
    (if (find-field body 'slot)
        (read-slot (req 'slot))
        'default))
  (spec name-value version-value summary-value source-value
        (if (find-field body 'deps)
            (read-deps (req 'deps))
            '())
        (if (find-field body 'build-deps)
            (read-build-deps (req 'build-deps))
            '())
        (read-build (req 'build))
        (read-install (req 'install))
        (syntax->datum (one (req 'license)))
        (let ((home (syntax->datum (one (req 'homepage)))))
          (unless (string? home)
            (fail (one (req 'homepage)) "homepage must be a string"))
          home)
        (if extend-form (read-extends extend-form) #f)
        (if variant-form (read-variants variant-form) '())
        (for/list ([f (in-list body)]
                   #:when (eq? (syntax->datum (car (syntax->list f)))
                               'when))
          (read-when f known-flags))
        slot-value
        flags-value))

;; ---------------------------------------------------------------------------
