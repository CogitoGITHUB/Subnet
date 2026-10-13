#lang racket/base
;; spec-read.rkt -- read and validate .rktd spec files. No syntax/parse
;; at runtime (D-014): a hand-written table-driven validator walks the
;; read-syntax objects so every error carries file:line:col (D-3, D-4).

(require racket/contract/base
         racket/port
         racket/runtime-path
         racket/string
         "errors.rkt"
         "security.rkt"
         "version.rkt"
         "git-id.rkt"
         "git-url.rkt"
         "spec.rkt")

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
(define known-keys
  '(format-version name version summary source deps build-deps build
                   install license homepage extends variants slot flags))

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

;; symbol -> string, closest known key within 2 edits, or ""
(define (suggest-key head)
  (define s (symbol->string head))
  (define best #f)
  (define best-d 3)
  (for ([k (in-list known-keys)])
    (define d (levenshtein s (symbol->string k)))
    (when (< d best-d)
      (set! best k)
      (set! best-d d)))
  (if best
      (format " (did you mean '~a?)" best)
      ""))

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
                                         (suggest-key head)
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
            (let ((cell (assoc "reason" (exn:fail:pm-fields e))))
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

;; ---------------------------------------------------------------------------
;; Field readers (each returns plain data for the struct)

;; syntax -> exact-integer 2
(define (read-format-version form)
  (define (v) (car (field-args form 1 'format-version)))
  (define n (syntax->datum (v)))
  (unless (and (exact-integer? n) (= n 2))
    (fail (v) (format "unsupported format-version ~a (neutral spec needs 2; see ~a)"
                      n "docs/SPEC-NEUTRAL.org section 9")))
  n)

;; syntax -> source
(define (read-source form)
  (define (v) (car (field-args form 1 'source)))
  (define inner (syntax->list (v)))
  (unless (and inner (= (length inner) 3)
               (eq? (syntax->datum (car inner)) 'git))
    (fail (v) "source must be (git URL COMMIT)"))
  (source (convert-url (cadr inner)) (convert-commit (caddr inner))))

;; syntax -> (listof dep)
(define (read-deps form)
  (define vals (field-args form 1 'deps))
  (define items (syntax->list (car vals)))
  (unless items
    (fail (car vals) "deps must be a list"))
  (for/list ([item (in-list items)])
    (define pair (syntax->list item))
    (if (and pair (= (length pair) 2))
        (dep (convert-name (car pair))
             (convert-version (cadr pair)))
        (fail item "dep must be (NAME VERSION)"))))

;; syntax -> (listof dep), same shape as deps, build-time only
(define (read-build-deps form)
  (define vals (field-args form 1 'build-deps))
  (define items (syntax->list (car vals)))
  (unless items
    (fail (car vals) "build-deps must be a list"))
  (for/list ([item (in-list items)])
    (define pair (syntax->list item))
    (if (and pair (= (length pair) 2))
        (dep (convert-name (car pair))
             (convert-version (cadr pair)))
        (fail item "build-dep must be (NAME VERSION)"))))
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
    (fail stx (format "[path-escape] install path '~a escapes the prefix" p)))
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
           (fail f (format "[install-mode] mode ~a refused; pm writes only 755 and 644"
                           (cadr args))))]
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
       (fail (cadr cond-parts)
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
(module+ test
  (require rackunit
           racket/file
           "errors.rkt"
           "spec.rkt"
           "version.rkt")

  ;; S-03: every negative fixture in docs/examples-bad refuses with its
  ;; rule's own name. These files are the declarations pm must never
  ;; accept, and this test is what keeps them honest.
  (define-runtime-path spec-core-dir
    "."
  )
  (define bad-dir
    (simplify-path
      (build-path spec-core-dir 'up "docs" "examples-bad"
      )
    )
  )
  (define bad-cases
    (list
      (cons "bad-pin.rktd" "source-trust"
      )
      (cons "bad-url.rktd" "origin"
      )
      (cons "bad-path.rktd" "path-escape"
      )
      (cons "bad-mode.rktd" "install-mode"
      )
    )
  )
  (for
    (
      [pair (in-list bad-cases)
      ]
    )
    (define err
      (with-handlers
        (
          [exn:fail:pm? (lambda (e) e)
          ]
        )
        (read-spec-file
          (path->string
            (build-path bad-dir (car pair)
            )
          )
        )
        'no-error
      )
    )
    (check-pred spec-error? err (car pair)
    )
    (check-regexp-match
      (regexp
        (string-append "\\[" (cdr pair) "\\]"
        )
      )
      (exn-message err
      )
      (car pair
      )
    )
  )

  ;; string (listof string) -> path, fixture file in a fresh temp dir
  (define (write-fixture name lines)
    (define dir (make-temporary-directory "pm-spec~a"))
    (call-with-output-file (build-path dir name)
      (lambda (out)
        (for ([line (in-list lines)])
          (displayln line out))))
    dir)

  ;; (listof string) -> string, the full pm message (or NO-ERROR)
  (define (message-for lines)
    (define dir (write-fixture "pkg.rktd" lines))
    (define result
      (parameterize ([current-directory dir])
        (with-handlers ([exn:fail:pm? exn-message])
          (read-spec-file "pkg.rktd")
          "NO-ERROR")))
    (delete-directory/files dir)
    result)

  ;; Full golden spec exercises every field.
  (define golden-dir
    (write-fixture
     "golden.rktd"
     '("(spec"
       "  (format-version 2)"
       "  (name demo)"
       "  (version \"2.9.1\")"
       "  (summary \"demo package\")"
       "  (source (git \"https://example.org/demo.git\""
       "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
       "  (deps ((pkg-beta \"1.0\")))"
       "  (build-deps ((pkg-gamma \"2.0\")))"
       "  (build (steps (copy \"a\" \"b\")))"
       "  (install (prefix (bin \"demo\" \"bin/demo\") (check \"bin/demo\")))"
       "  (license gpl-3.0+)"
       "  (homepage \"https://example.org/demo\")"
       "  (extends base)"
       "  (variants ((lite (version \"1.0\"))))"
       "  (when (platform linux) ((version \"1.0\"))))")))
  (define golden
    (parameterize ([current-directory golden-dir])
      (read-spec-file "golden.rktd")))
  (check-true (spec? golden))
  (check-equal? (spec-name golden) 'demo)
  (check-equal? (version->string (spec-version golden)) "2.9.1")
  (check-equal? (source-commit (spec-source golden))
                "9edb3f66fd807b096b48283debdcddccfea34bad")
  (check-equal? (map dep-name (spec-deps golden)) '(pkg-beta))
  (check-equal? (map dep-name (spec-build-deps golden)) '(pkg-gamma))
  (check-equal? (build-step-name (car (spec-build golden))) 'copy)
  (check-equal? (install-spec-target (spec-install golden)) 'prefix)
  (check-equal? (length (install-spec-forms (spec-install golden))) 2)
  (check-equal? (spec-extends golden) 'base)
  (check-equal? (length (spec-variants golden)) 1)
  (check-equal? (length (spec-whens golden)) 1)
  (delete-directory/files golden-dir)

  ;; Minimal spec: deps, extends, variants and whens default out.
  (define minimal-dir
    (write-fixture
     "minimal.rktd"
     '("(spec"
       "  (format-version 2)"
       "  (name tiny)"
       "  (version \"1.0\")"
       "  (summary \"tiny\")"
       "  (source (git \"https://example.org/t.git\""
       "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
       "  (build (steps (copy \"a\" \"b\")))"
       "  (install (prefix (bin \"b\")))"
       "  (license mit)"
       "  (homepage \"https://example.org/t\"))")))
  (define minimal
    (parameterize ([current-directory minimal-dir])
      (read-spec-file "minimal.rktd")))
  (check-equal? (spec-deps minimal) '())
  (check-false (spec-extends minimal))
  (check-equal? (spec-variants minimal) '())
  (check-equal? (spec-whens minimal) '())
  (delete-directory/files minimal-dir)

  ;; Exact message 1: unknown key at 3:4, with a suggestion.
  (check-equal?
   (message-for '("(spec" "  (format-version 2)" "  (soruce \"x\"))"))
   (string-append "read-spec: invalid declaration;\n"
                  "  at: pkg.rktd:3:4\n"
                  "  hint: unknown key 'soruce (did you mean 'source?)"))

  ;; Exact message 1b: a v1 spec is rejected, never silently accepted.
  (check-equal?
   (message-for '("(spec" "  (format-version 1)" "  (name demo)"
                  "  (version \"1.0\")" "  (summary \"s\")"
                  "  (source (git \"https://example.org/d.git\""
                  "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
                  "  (build (steps (copy \"a\" \"b\")))"
                  "  (install (prefix (bin \"b\")))"
                  "  (license mit)"
                  "  (homepage \"https://example.org\"))"))
   (string-append "read-spec: invalid declaration;\n"
                  "  at: pkg.rktd:2:19\n"
                  "  hint: unsupported format-version 1 (neutral spec needs 2; see "
                  "docs/SPEC-NEUTRAL.org section 9)"))

  ;; G-12: a v9 spec gets the same rule's own message, not a field error.
  (check-equal?
   (message-for '("(spec" "  (format-version 9)" "  (name demo)"
                  "  (version \"1.0\")" "  (summary \"s\")"
                  "  (source (git \"https://example.org/d.git\""
                  "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
                  "  (build (steps (copy \"a\" \"b\")))"
                  "  (install (prefix (bin \"b\")))"
                  "  (license mit)"
                  "  (homepage \"https://example.org\"))"))
   (string-append "read-spec: invalid declaration;\n"
                  "  at: pkg.rktd:2:19\n"
                  "  hint: unsupported format-version 9 (neutral spec needs 2; see "
                  "docs/SPEC-NEUTRAL.org section 9)"))

  ;; Exact message 2: bad version value at 4:11.
  (check-equal?
   (message-for '("(spec" " (format-version 2)"
                  " (name demo)" " (version \"1..2\"))"))
   (string-append "read-spec: invalid declaration;\n"
                  "  at: pkg.rktd:4:11\n"
                  "  hint: invalid version \"1..2\""))

  ;; Exact message 3: missing source points at the top form.
  (check-equal?
   (message-for '("(spec" "  (format-version 2)" "  (name demo)"
                  "  (version \"1.0\")" "  (summary \"s\")"
                  "  (build (steps (copy \"a\" \"b\")))"
                  "  (install (prefix (bin \"b\")))"
                  "  (license mit)"
                  "  (homepage \"https://example.org\"))"))
   (string-append "read-spec: invalid declaration;\n"
                  "  at: pkg.rktd:1:1\n"
                  "  hint: missing required field 'source"))

  ;; Hostile inputs: every kind is 'spec with a telling hint.
  (define (hint-matches? lines pattern)
    (check-regexp-match pattern (message-for lines)))
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\" \"xyz\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"\\[source-trust\\] not a commit id")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"ext::sh -c true\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"\\[origin\\] rejected git URL")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name a)" "  (name b))")
   #rx"duplicate field")
  (hint-matches?
   '("(package" "  (name a))")
   #rx"expected \\(spec")
  (hint-matches? '("(((") #rx"cannot read declaration")
  (hint-matches? '() #rx"empty declaration")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (frobnicate)))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   (regexp (string-append "unknown build step 'frobnicate \\(valid: "
                           "cmake-build cmake-configure cmake-install configure "
                           "copy make make-info cargo run\\)")))
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (make #:dir \".\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"step 'make needs #:targets")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"../etc/passwd\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"\\[path-escape\\] install path '../etc/passwd escapes the prefix")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\") (mode \"bin/b\" 777)))"
     "  (license mit)" "  (homepage \"https://example.org\"))")
   #rx"\\[install-mode\\] mode 777 refused")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (check \"bin/a\") (check \"bin/b\")))"
     "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"only one check form per install")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (web ((x 1))))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"install must be")
  (hint-matches?
   '("(spec" "  (format-version 3)" "  (name demo))")
   #rx"unsupported format-version")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (deps ((pkg-beta)))" "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"dep must be")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\")"
     "  (when (os linux) ((version \"1.0\"))))")
   #rx"unknown condition")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\")"
     "  (variants ((lite (name other)))))")
   #rx"must not override")
  ;; Trailing data after the form is an error, not silence.
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))" "42")
   #rx"trailing data")
  ;; Kind is always spec, even for hostile bytes.
  (check-pred spec-error?
              (let ((dir (write-fixture "pkg.rktd" '("(spec"))))
                (define result
                  (parameterize ([current-directory dir])
                    (with-handlers ([exn:fail:pm? (lambda (e) e)])
                      (read-spec-file "pkg.rktd")
                      'no-error)))
                (delete-directory/files dir)
                result)))

  ;; string (listof string) -> symbol, the pm kind (or 'no-error).
  ;; Second test block: Racket merges repeated (module+ test) bodies into
  ;; the one test submodule, so these see write-fixture and friends above.
(module+ test
  (define (kind-for lines)
    (define dir (write-fixture "pkg.rktd" lines))
    (define result
      (parameterize ([current-directory dir])
        (with-handlers ([exn:fail:pm? exn:fail:pm-kind])
          (read-spec-file "pkg.rktd")
          'no-error)))
    (delete-directory/files dir)
    result)

  ;; E-02: a (flag NAME) cond naming an undeclared flag is kind 'spec
  ;; with a srcloc pointing at the NAME, not the file.
  (define unknown-flag-lines
    '("(spec" "  (format-version 2)" "  (name demo)"
      "  (version \"1.0\")" "  (summary \"s\")"
      "  (source (git \"https://example.org/d.git\""
      "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
      "  (build (steps (copy \"a\" \"b\")))"
      "  (install (prefix (bin \"b\")))" "  (license mit)"
      "  (homepage \"https://example.org\")"
      "  (flags ((gui #:default #t #:doc \"Graphical interface\")))"
      "  (when (flag cli) ((version \"1.0\"))))"))
  (check-eq? (kind-for unknown-flag-lines) 'spec)
  (hint-matches? unknown-flag-lines #rx"unknown flag 'cli")
  (hint-matches? unknown-flag-lines #rx"at: pkg.rktd:[0-9]+:[0-9]+")

  ;; E-02: a second (slot ...) field is a duplicate slot, kind 'spec
  ;; with a srcloc (the generic duplicate-field check names the key).
  (define duplicate-slot-lines
    '("(spec" "  (format-version 2)" "  (name demo)"
      "  (version \"1.0\")" "  (summary \"s\")"
      "  (source (git \"https://example.org/d.git\""
      "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
      "  (build (steps (copy \"a\" \"b\")))"
      "  (install (prefix (bin \"b\")))" "  (license mit)"
      "  (homepage \"https://example.org\")"
      "  (slot lts)" "  (slot stable))"))
  (check-eq? (kind-for duplicate-slot-lines) 'spec)
  (hint-matches? duplicate-slot-lines #rx"duplicate field 'slot")
  (hint-matches? duplicate-slot-lines #rx"at: pkg.rktd:[0-9]+:[0-9]+")

  ;; E-02 positive: slot, flags and a flag cond read through; a spec
  ;; without them defaults to slot 'default and no flags.
  (define flagged-dir
    (write-fixture
     "flagged.rktd"
     '("(spec"
       "  (format-version 2)"
       "  (name demo)"
       "  (version \"1.0\")"
       "  (summary \"s\")"
       "  (source (git \"https://example.org/d.git\""
       "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
       "  (build (steps (copy \"a\" \"b\")))"
       "  (install (prefix (bin \"b\")))" "  (license mit)"
       "  (homepage \"https://example.org\")"
       "  (slot lts)"
       "  (flags ((gui #:default #t #:doc \"Graphical interface\""
       "               #:conflicts (minimal) #:requires (x11))"
       "          (minimal #:default #f #:doc \"No extras\")))"
       "  (when (flag gui) ((version \"2.0\"))))")))
  (define flagged
    (parameterize ([current-directory flagged-dir])
      (read-spec-file "flagged.rktd")))
  (check-eq? (spec-slot flagged) 'lts)
  (check-equal? (map flag-spec-name (spec-flags flagged)) '(gui minimal))
  (check-equal? (flag-spec-conflicts (car (spec-flags flagged))) '(minimal))
  (check-equal? (flag-spec-requires (car (spec-flags flagged))) '(x11))
  (check-equal? (when-spec-cond (car (spec-whens flagged))) '(flag gui))
  (delete-directory/files flagged-dir)
  (check-eq? (spec-slot minimal) 'default)
  (check-equal? (spec-flags minimal) '())
  ;; A duplicate flag name is kind 'spec on the second NAME.
  (check-eq? (kind-for
              '("(spec" "  (format-version 2)" "  (name demo)"
                "  (version \"1.0\")" "  (summary \"s\")"
                "  (source (git \"https://example.org/d.git\""
                "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
                "  (build (steps (copy \"a\" \"b\")))"
                "  (install (prefix (bin \"b\")))" "  (license mit)"
                "  (homepage \"https://example.org\")"
                "  (flags ((gui #:default #t #:doc \"G\")"
                "          (gui #:default #f #:doc \"G2\"))))"))
            'spec)
  ;; end of E-02 tests
  )
