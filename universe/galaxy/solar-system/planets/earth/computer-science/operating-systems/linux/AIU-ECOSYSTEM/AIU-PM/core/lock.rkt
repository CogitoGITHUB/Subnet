#lang racket/base
;; lock.rkt -- lockfile read and write (atomic, sorted). No network.
;; Format (D-004): (lockfile (format-version 2) (pins (ENTRY ...)))
;; with ENTRY = (NAME VERSION COMMIT URL SLOT FLAGS SPEC-HASH INPUT-HASH
;;                (DEPS ...)), sorted by NAME then SLOT for diffs.
;; Version 2 is the D-028 shape (E-05 extends, never rewrites): version 1
;; entries carried only (NAME VERSION COMMIT URL) and no reader for them
;; remains; a version-1 file fails closed as unsupported.

(require racket/contract/base
         racket/file
         racket/port
         openssl/sha1
         "errors.rkt"
         "version.rkt"
         "git-id.rkt"
         "git-url.rkt"
         "spec.rkt"
         "plan.rkt"
         "verbose.rkt")

(provide
 (struct-out lock-entry)
 (struct-out lockfile)
 (contract-out
  ;; path-string -> lockfile, bad input raises kind 'spec with srcloc
  [read-lockfile (-> path-string? lockfile?)]
  ;; path-string lockfile -> void, atomic write with sorted entries
  [write-lockfile (-> path-string? lockfile? void?)]
  ;; (listof entry-datum) -> lockfile, validated; same name+slot with
  ;; different commits raises kind 'config
  [list->lock (-> (listof list?) lockfile?)]
  ;; lockfile -> (listof entry-datum), canonical sorted order
  [lock->list (-> lockfile? (listof list?))]
  ;; package-plan string -> entry-datum, the lock row for one plan; the
  ;; url travels beside the plan because plans carry pins, not locations
  [plan->lock-entry (-> package-plan? string? (listof any/c))]))

;; ---------------------------------------------------------------------------
;; Data

(struct lock-entry (name version commit url slot flags spec-hash input-hash
                         deps)
  #:transparent
  #:guard (lambda (name version commit url slot flags spec-hash input-hash
                        deps _n)
            (unless (package-name? name)
              (raise-pm-error 'spec 'lock-entry "bad package name"
                              #:fields `(("value" . ,name))))
            (unless (version? version)
              (raise-pm-error 'spec 'lock-entry "not a version"
                              #:fields `(("value" . ,version))))
            (unless (git-id? commit)
              (raise-pm-error 'spec 'lock-entry "not a commit id"
                              #:fields `(("value" . ,commit))))
            (unless (and (string? url) (> (string-length url) 0))
              (raise-pm-error 'spec 'lock-entry "url must be nonempty"
                              #:fields `(("value" . ,url))))
            (unless (slot-name? slot)
              (raise-pm-error 'spec 'lock-entry "bad slot name"
                              #:fields `(("value" . ,slot))))
            (unless (and (list? flags)
                         (andmap (lambda (p)
                                   (and (pair? p)
                                        (symbol? (car p))
                                        (boolean? (cdr p))))
                                 flags))
              (raise-pm-error 'spec 'lock-entry "flags must be name.value"
                              #:fields `(("value" . ,flags))))
            (unless (and (string? spec-hash) (> (string-length spec-hash) 0))
              (raise-pm-error 'spec 'lock-entry "spec hash must be nonempty"
                              #:fields `(("value" . ,spec-hash))))
            (unless (and (string? input-hash) (> (string-length input-hash) 0))
              (raise-pm-error 'spec 'lock-entry "input hash must be nonempty"
                              #:fields `(("value" . ,input-hash))))
            (unless (and (list? deps) (andmap string? deps))
              (raise-pm-error 'spec 'lock-entry "deps must be strings"
                              #:fields `(("value" . ,deps))))
            (values name version commit url slot flags spec-hash input-hash
                    deps)))
;; name       : package-name?  D-8
;; version    : version?       exact pin, matches spec equality
;; commit     : string?        full commit id the version resolves to (base pin)
;; url        : string?        git URL (scheme checked on read)
;; slot       : slot-name?     version stream (D-023)
;; flags      : (listof (cons symbol boolean))  resolved, full coverage
;; spec-hash  : string?        sha1 over the spec build/install rendering
;; input-hash : string?        sha1 over the derived plan (D-023 identity)
;; deps       : (listof string?)  "name version" identities, sorted

(struct lockfile (entries)
  #:transparent
  #:guard (lambda (entries _n)
            (unless (and (list? entries) (andmap lock-entry? entries))
              (raise-pm-error 'spec 'lockfile "entries must be lock entries"
                              #:fields `(("value" . ,entries))))
            (values entries)))
;; entries : (listof lock-entry?)  canonical sorted order by name

;; ---------------------------------------------------------------------------
;; Safe reading (D-3: same discipline as spec-read, owned by this format)

(define max-lock-bytes 1000000)

;; path-string -> syntax, one datum safely with source locations
;; Missing or unreadable files raise kind 'spec, never a raw error.
(define (lock-read-one path)
  (with-handlers
      ([exn:fail:filesystem?
        (lambda (e)
          (raise-pm-error 'spec 'read-lockfile
                          "cannot read lockfile"
                          #:fields `(("file" . ,(path-text path)))
                          #:cause e))])
    (call-with-input-file path
    (lambda (in)
      (define limited (make-limited-input-port in max-lock-bytes #f))
      (port-count-lines! limited)
      (parameterize ([read-accept-reader #f]
                     [read-accept-lang #f]
                     [read-accept-compiled #f])
        (with-handlers
            ([exn:fail:read?
              (lambda (e)
                (raise-pm-error 'spec 'read-lockfile
                                "cannot read lockfile"
                                #:fields `(("file" . ,(path-text path)))
                                #:cause e))])
          (define first-datum (read-syntax path limited))
          (cond [(eof-object? first-datum)
                 (raise-pm-error 'spec 'read-lockfile "empty lockfile"
                                 #:fields `(("file" . ,(path-text path))))]
                [(eof-object? (read-syntax path limited)) first-datum]
                [else
                 (raise-pm-error 'spec 'read-lockfile "trailing data"
                                 #:fields `(("file" . ,(path-text path)))
                                 #:hint "one (lockfile ...) form per file")])))))))

;; path-string -> string, for fields (paths and strings both allowed in)
(define (path-text p)
  (if (path? p) (path->string p) p))

;; syntax -> string, file:line:col of STX for messages
(define (lock-loc-string stx)
  (format "~a:~a:~a"
          (or (syntax-source stx) "?")
          (or (syntax-line stx) "?")
          (let ((c (syntax-column stx))) (if c (+ c 1) "?"))))

;; syntax string -> never returns (E-1, E-2, E-4)
(define (lock-fail stx hint)
  (raise-pm-error 'spec 'read-lockfile "invalid lockfile"
                  #:fields `(("at" . ,(lock-loc-string stx)))
                  #:hint hint))

;; ---------------------------------------------------------------------------
;; Validation (hand table like spec-read: no syntax/parse at runtime)

;; (listof syntax) -> void, unknown keys and duplicates are errors (D-2)
(define (lock-check-keys forms)
  (define seen '())
  (for ([f (in-list forms)])
    (define parts (syntax->list f))
    (if (not (and parts (pair? parts)))
        (lock-fail f "expected a (KEY ...) form")
        (set! seen (lock-check-one (car parts) seen))))
  (void))

;; syntax (listof symbol) -> (listof symbol), records KEY or fails
;; Lockfiles have no when-clauses: a stray `when` head is unknown.
(define (lock-check-one key-stx seen)
  (define head (syntax->datum key-stx))
  (cond [(memq head '(format-version pins))
         (if (memq head seen)
             (lock-fail key-stx (format "duplicate field '~a" head))
             (cons head seen))]
        [else (lock-fail key-stx (format "unknown key '~a" head))]))

;; (listof syntax) symbol -> (or/c syntax #f), the field form for KEY
(define (lock-find-field forms key)
  (for/or ([f (in-list forms)])
    (define parts (syntax->list f))
    (and parts (pair? parts)
         (eq? (syntax->datum (car parts)) key)
         f)))

;; (listof syntax) symbol syntax -> syntax, missing fields are errors
(define (lock-need-field forms key top)
  (or (lock-find-field forms key)
      (lock-fail top (format "missing required field '~a" key))))

;; syntax -> version, bad input names the value at its location
(define (lock-convert-version stx)
  (define v (syntax->datum stx))
  (if (not (string? v))
      (lock-fail stx "version must be a string")
      (with-handlers
          ([exn:fail:pm?
            (lambda (_) (lock-fail stx (format "invalid version ~s" v)))])
        (string->version v))))

;; syntax -> string, validated commit id or a located error
(define (lock-convert-commit stx)
  (define c (syntax->datum stx))
  (if (and (string? c) (git-id? c))
      c
      (lock-fail stx (format "not a commit id ~s" c))))

;; syntax -> slot symbol or a located error
(define (lock-convert-slot stx)
  (define s (syntax->datum stx))
  (if (slot-name? s)
      s
      (lock-fail stx (format "bad slot name ~s" s))))

;; syntax -> (listof (cons symbol boolean)), flag alist or a located error
(define (lock-convert-flags stx)
  (define v (syntax->datum stx))
  (if (and (list? v)
           (andmap (lambda (p)
                     (and (pair? p) (symbol? (car p)) (boolean? (cdr p))))
                   v))
      v
      (lock-fail stx (format "flags must be name.value pairs, got ~s" v))))

;; string syntax -> string, nonempty hash or a located error
(define (lock-convert-hash stx what)
  (define h (syntax->datum stx))
  (if (and (string? h) (> (string-length h) 0))
      h
      (lock-fail stx (format "~a must be a nonempty string" what))))

;; syntax -> (listof string), dep identities or a located error
(define (lock-convert-deps stx)
  (define v (syntax->datum stx))
  (if (and (list? v) (andmap string? v))
      v
      (lock-fail stx (format "deps must be strings, got ~s" v))))

;; syntax -> string, validated git URL or a located error
(define (lock-convert-url stx)
  (define u (syntax->datum stx))
  (if (not (string? u))
      (lock-fail stx "URL must be a string")
      (with-handlers
          ([exn:fail:pm?
            (lambda (e)
              (define cell (assoc "reason" (exn:fail:pm-fields e)))
              (define reason (if cell (cdr cell) "?"))
              (lock-fail stx (format "rejected git URL ~s (~a" u reason)))])
        (check-git-url u)
        u)))

;; syntax -> package-name symbol or a located error
(define (lock-convert-name stx)
  (define n (syntax->datum stx))
  (if (package-name? n)
      n
      (lock-fail stx (format "invalid package name ~s" n))))

;; syntax -> lock-entry, one (NAME VERSION COMMIT URL SLOT FLAGS
;; SPECHASH INPUTHASH (DEPS ...)) datum
(define (lock-read-entry item)
  (define parts (syntax->list item))
  (if (not (and parts (= (length parts) 9)))
      (lock-fail item
                 (string-append
                  "pin must be (NAME VERSION COMMIT URL SLOT FLAGS "
                  "SPECHASH INPUTHASH (DEPS ...))"))
      (lock-entry (lock-convert-name (car parts))
                  (lock-convert-version (cadr parts))
                  (lock-convert-commit (caddr parts))
                  (lock-convert-url (cadddr parts))
                  (lock-convert-slot (car (cddddr parts)))
                  (lock-convert-flags (cadr (cddddr parts)))
                  (lock-convert-hash (caddr (cddddr parts)) "spec hash")
                  (lock-convert-hash (cadddr (cddddr parts)) "input hash")
                  (lock-convert-deps (car (cddddr (cddddr parts)))))))

;; path-string -> lockfile (D-1 style: one immutable value per file)
(define (read-lockfile path)
  (define top (lock-read-one path))
  (define forms (syntax->list top))
  (if (not (and forms (pair? forms)
                (eq? (syntax->datum (car forms)) 'lockfile)))
      (lock-fail top "expected (lockfile ...)")
      (read-lockfile-body (cdr forms) top)))

;; (listof syntax) syntax -> lockfile, top locates missing fields
(define (read-lockfile-body body top)
  (lock-check-keys body)
  (define version-form (lock-need-field body 'format-version top))
  (define pins-form (lock-need-field body 'pins top))
  (read-lockfile-checked version-form pins-form))

;; syntax symbol -> syntax, the single value form or a located error
(define (lock-one-arg form key)
  (define parts (syntax->list form))
  (if (and parts (= (length parts) 2))
      (cadr parts)
      (lock-fail form (format "field '~a takes exactly one value" key))))

;; lock-entry lock-entry -> boolean, name then slot (stable diffs)
(define (lock-entry<? a b)
  (define an (symbol->string (lock-entry-name a)))
  (define bn (symbol->string (lock-entry-name b)))
  (or (string<? an bn)
      (and (string=? an bn)
           (string<? (symbol->string (lock-entry-slot a))
                     (symbol->string (lock-entry-slot b))))))

;; syntax syntax -> lockfile
(define (read-lockfile-checked version-form pins-form)
  (define version-arg (lock-one-arg version-form 'format-version))
  (define version-value (syntax->datum version-arg))
  (if (not (and (exact-integer? version-value) (= version-value 2)))
      (lock-fail version-arg
                 (format "unsupported format-version ~s" version-value))
      (read-lockfile-pins pins-form)))

;; syntax -> lockfile
(define (read-lockfile-pins pins-form)
  (define items-form (lock-one-arg pins-form 'pins))
  (define items (syntax->list items-form))
  (if (not items)
      (lock-fail items-form "pins must be a list")
      (lockfile (sort (for/list ([item (in-list items)])
                        (lock-read-entry item))
                      lock-entry<?))))

;; ---------------------------------------------------------------------------
;; Writing (atomic, sorted for meaningful diffs per D-6)

;; path-string lockfile -> void, temp file in place plus rename (F-3)
(define (write-lockfile path lf)
  (define sorted (sort (lockfile-entries lf) lock-entry<?))
  ;; D-036: writing the lock is the moment the whole closure becomes
  ;; reproducible, so it narrates how many pins went down and that they
  ;; went down sorted, which is what makes two locks byte-identical.
  (step 'lock
        (string-append "the resolved set is pinned for "
                       (number->string (length sorted)) " package(s)")
        "entries are sorted by name so two resolutions produce one file"
        #:how (if (path? path) (path->string path) (format "~a" path)))
  (call-with-atomic-output-file path
    (lambda (out tmp)
      (write `(lockfile (format-version 2)
                        (pins ,(for/list ([e (in-list sorted)])
                                 (list (lock-entry-name e)
                                       (version->string
                                        (lock-entry-version e))
                                       (lock-entry-commit e)
                                       (lock-entry-url e)
                                       (lock-entry-slot e)
                                       (lock-entry-flags e)
                                       (lock-entry-spec-hash e)
                                       (lock-entry-input-hash e)
                                       (lock-entry-deps e)))))
             out)
      (newline out))))

;; ---------------------------------------------------------------------------
;; Datum converters (E-05: plans in, plain data out and back)

;; entry-datum = (NAME VERSION COMMIT URL SLOT FLAGS SPECHASH INPUTHASH
;; (DEPS ...)), all plain data: symbols, strings, a flag alist and a
;; string list. list->lock validates every row through lock-entry, so a
;; bad row raises kind 'spec naming the value.

;; (listof entry-datum) -> lockfile, sorted; same name+slot pinned to two
;; different commits is caller error, kind 'config (two slots of one
;; package with different commits are fine: the key is name AND slot)
(define (list->lock rows)
  (define entries
    (for/list ([row (in-list rows)])
      (unless (and (list? row) (= (length row) 9))
        (raise-pm-error 'spec 'list->lock
                        "entry must be 8 plain values"
                        #:fields `(("value" . ,(format "~s" row)))))
      (lock-entry (car row)
                  (string->version-checked (cadr row) row)
                  (caddr row)
                  (cadddr row)
                  (car (cddddr row))
                  (cadr (cddddr row))
                  (caddr (cddddr row))
                  (cadddr (cddddr row))
                  (car (cddddr (cddddr row))))))
  (check-dup-pins entries)
  (lockfile (sort entries lock-entry<?)))

;; entry-datum string -> version, bad input raises kind 'spec
(define (string->version-checked v row)
  (if (not (string? v))
      (raise-pm-error 'spec 'list->lock "version must be a string"
                      #:fields `(("row" . ,(format "~s" row))))
      (with-handlers
          ([exn:fail:pm?
            (lambda (_) (raise-pm-error 'spec 'list->lock
                                       "not a version"
                                       #:fields `(("row" . ,(format "~s" row)))))])
        (string->version v))))

;; (listof lock-entry) -> void, duplicate pins are kind 'config
(define (check-dup-pins entries)
  (define seen (make-hash))
  (for ([e (in-list entries)])
    (define key (cons (lock-entry-name e) (lock-entry-slot e)))
    (define prev (hash-ref seen key #f))
    (cond [(not prev) (hash-set! seen key (lock-entry-commit e))]
          [(equal? prev (lock-entry-commit e)) (void)]
          [else
           (raise-pm-error 'config 'list->lock "same slot pinned twice"
                           #:fields `(("package" . ,(format "~a" (car key)))
                                      ("slot" . ,(format "~a" (cdr key)))))])))

;; lockfile -> (listof entry-datum), canonical sorted order: the exact
;; inverse of list->lock, so datum -> lockfile -> datum round-trips byte
;; for byte after write/read (write sorts, read sorts, both by lock-entry<?)
(define (lock->list lf)
  (for/list ([e (in-list (sort (lockfile-entries lf) lock-entry<?))])
    (list (lock-entry-name e)
          (version->string (lock-entry-version e))
          (lock-entry-commit e)
          (lock-entry-url e)
          (lock-entry-slot e)
          (lock-entry-flags e)
          (lock-entry-spec-hash e)
          (lock-entry-input-hash e)
          (lock-entry-deps e))))

;; package-plan string -> entry-datum, the lock row for one derived plan.
;; The url travels beside the plan because plans carry pins (D-007), not
;; locations; spec-hash covers the spec build/install rendering.
(define (plan->lock-entry pp url)
  (list (package-plan-name pp)
        (version->string (package-plan-version pp))
        (package-plan-commit pp)
        url
        (package-plan-slot pp)
        (package-plan-flags pp)
        (spec-build-install-hash (package-plan-steps pp)
                                 (install-spec-forms
                                  (package-plan-install pp)))
        (package-plan-input-hash pp)
        (package-plan-deps pp)))

;; (listof build-step) list -> string, sha1 over the stable rendering of
;; the spec build and install forms (E-05 input to the lock's spec hash)
(define (spec-build-install-hash steps forms)
  (bytes->hex-string
   (sha1-bytes
    (open-input-string
     (format "~s" (list (for/list ([s (in-list steps)])
                          (list (build-step-name s)
                                (build-step-args s)))
                        forms))))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           "errors.rkt"
           "version.rkt"
           "spec.rkt")

  ;; Guards reject with kind 'spec.
  (define (lock-kind thunk)
    (with-handlers ([exn:fail:pm? exn:fail:pm-kind])
      (thunk)
      #f))
  (check-eq? (lock-kind (lambda ()
                          (lock-entry 'Bad! (string->version "1.0")
                                      (make-string 40 #\a)
                                      "https://example.org/x.git"
                                      'default '() "s" "i" '())))
             'spec)
  (check-eq? (lock-kind (lambda ()
                          (lock-entry 'demo (string->version "1.0")
                                      "xyz"
                                      "https://example.org/x.git"
                                      'default '() "s" "i" '())))
             'spec)
  (check-eq? (lock-kind (lambda ()
                          (lock-entry 'demo (string->version "1.0")
                                      (make-string 40 #\a)
                                      "https://example.org/x.git"
                                      'Bad! '() "s" "i" '())))
             'spec)
  (check-eq? (lock-kind (lambda ()
                          (lock-entry 'demo (string->version "1.0")
                                      (make-string 40 #\a)
                                      "https://example.org/x.git"
                                      'default '((gui . "yes")) "s" "i" '())))
             'spec)
  (check-eq? (lock-kind (lambda () (lockfile '(1 2)))) 'spec)

  ;; Round trip preserves every field of the D-028 shape.
  (define round-dir (make-temporary-directory "pm-lock~a"))
  (define round-path (build-path round-dir "lockfile.rktd"))
  (define round-entry
    (lock-entry 'demo (string->version "2.9.1")
                "9edb3f66fd807b096b48283debdcddccfea34bad"
                "https://example.org/demo.git"
                'lts '((gui . #t)) "spec-hash-1" "input-hash-1"
                '("pkg-beta 1.0")))
  (write-lockfile round-path (lockfile (list round-entry)))
  (define round-back (read-lockfile round-path))
  (check-true (lockfile? round-back))
  (check-equal? (map lock-entry-name (lockfile-entries round-back))
                '(demo))
  (check-equal? (version->string
                 (lock-entry-version (car (lockfile-entries round-back))))
                "2.9.1")
  (check-eq? (lock-entry-slot (car (lockfile-entries round-back))) 'lts)
  (check-equal? (lock-entry-flags (car (lockfile-entries round-back)))
                '((gui . #t)))
  (check-equal? (lock-entry-deps (car (lockfile-entries round-back)))
                '("pkg-beta 1.0"))

  ;; The writer sorts by name then slot whatever the input order.
  (define (sort-entry name slot)
    (lock-entry name (string->version "1.0") (make-string 40 #\a)
                (string-append "https://example.org/"
                               (symbol->string name) ".git")
                slot '() "s" "i" '()))
  (write-lockfile round-path (lockfile (list (sort-entry 'zzz 'default)
                                             (sort-entry 'aaa 'default)
                                             (sort-entry 'aaa 'lts))))
  (check-equal? (map (lambda (e) (list (lock-entry-name e)
                                       (lock-entry-slot e)))
                     (lockfile-entries (read-lockfile round-path)))
                '((aaa default) (aaa lts) (zzz default)))

  ;; G-02: the lock records the whole closure row: name, version, slot,
  ;; flags, commit and source URL survive the round trip.
  (check-equal? (lock-entry-commit (car (lockfile-entries round-back)))
                "9edb3f66fd807b096b48283debdcddccfea34bad")
  (check-equal? (lock-entry-url (car (lockfile-entries round-back)))
                "https://example.org/demo.git")

  ;; G-02: two locks from the same entries in different orders are
  ;; byte-identical on disk, so a closure is reproducible bit for bit.
  (define lock-a (build-path round-dir "a.rktd"))
  (define lock-b (build-path round-dir "b.rktd"))
  (write-lockfile lock-a (lockfile (list (sort-entry 'zzz 'default)
                                         (sort-entry 'aaa 'lts)
                                         (sort-entry 'aaa 'default))))
  (write-lockfile lock-b (lockfile (list (sort-entry 'aaa 'default)
                                         (sort-entry 'aaa 'lts)
                                         (sort-entry 'zzz 'default))))
  (check-equal? (file->string lock-a) (file->string lock-b))
  (delete-directory/files round-dir)

  ;; string -> string, validation message for a lockfile text
  (define (lock-message-for text)
    (define dir (make-temporary-directory "pm-lock~a"))
    (define path (build-path dir "lockfile.rktd"))
    (call-with-output-file path
      (lambda (out) (display text out)))
    (define result
      (with-handlers ([exn:fail:pm? exn-message])
        (read-lockfile path)
        "NO-ERROR"))
    (delete-directory/files dir)
    result)

  ;; Hostile inputs fail with telling messages, kind 'spec.
  (check-regexp-match #rx"unknown key"
                      (lock-message-for
                       "(lockfile (format-version 1) (nope ()) (pins ()))"))
  (check-regexp-match #rx"missing required field 'pins"
                      (lock-message-for
                       "(lockfile (format-version 1))"))
  (check-regexp-match #rx"unsupported format-version"
                      (lock-message-for
                       "(lockfile (format-version 3) (pins ()))"))
  ;; Hostile entry datums are built with format + quote, never by hand-counting
  ;; string escapes: the reader balances the datum, ~s renders it readably.
  (check-regexp-match #rx"not a commit id"
                      (lock-message-for
                       (format "(lockfile (format-version 2) (pins (~s)))"
                               '(demo "1.0" "xyz" "https://example.org/d.git"
                                      default () "s" "i" ()))))
  (check-regexp-match #rx"rejected git URL"
                      (lock-message-for
                       (format "(lockfile (format-version 2) (pins (~s)))"
                               `(demo "1.0" ,(make-string 40 #\a)
                                      "ext::sh -c true"
                                      default () "s" "i" ()))))
  (check-regexp-match #rx"cannot read lockfile"
                      (lock-message-for "(lockfile (format-version 1)"))
  (check-regexp-match #rx"empty lockfile" (lock-message-for ""))
  (check-regexp-match #rx"trailing data"
                      (lock-message-for
                       "(lockfile (format-version 1) (pins ())) 42"))
  (check-pred spec-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (read-lockfile "/nonexistent-pm-dir/lockfile.rktd")
                'no-error))

  ;; E-05 converters: datum -> lockfile -> datum round-trips sorted,
  ;; whatever the input order.
  (define lock-row-a
    (list 'aaa "1.0" (make-string 40 #\a) "https://example.org/a.git"
          'default '() "spec-a" "input-a" '()))
  (define lock-row-z
    (list 'zzz "1.0" (make-string 40 #\f) "https://example.org/z.git"
          'lts '((gui . #t)) "spec-z" "input-z" '("pkg-beta 1.0")))
  (check-equal? (lock->list (list->lock (list lock-row-z lock-row-a)))
                (list lock-row-a lock-row-z))

  ;; File round trip keeps the v2 shape and the order.
  (define conv-dir (make-temporary-directory "pm-lock~a"))
  (define conv-path (build-path conv-dir "lockfile.rktd"))
  (write-lockfile conv-path (list->lock (list lock-row-z lock-row-a)))
  (check-equal? (lock->list (read-lockfile conv-path))
                (list lock-row-a lock-row-z))
  (delete-directory/files conv-dir)

  ;; Same name+slot pinned twice to different commits is kind 'config.
  (define lock-row-a2
    (list 'aaa "2.0" (make-string 40 #\b) "https://example.org/a.git"
          'default '() "spec-a2" "input-a2" '()))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (list->lock (list lock-row-a lock-row-a2))
                'no-error))

  ;; A plan whose flags changed produces a different input hash, end to
  ;; end through plan->lock-entry.
  (define hash-spec
    (spec 'demo (string->version "1.0") "demo"
          (source "https://example.org/d.git"
                  "9edb3f66fd807b096b48283debdcddccfea34bad")
          '() '()
          (list (build-step 'copy '("a" "b")))
          (install-spec 'prefix '((bin "b")))
          'mit "https://example.org" #f '() '()
          'default
          (list (flag-spec 'gui #t "GUI" '() '()))))
  (define (lock-row-for resolved)
    (plan->lock-entry
     (derive-package-plan hash-spec resolved '())
     "https://example.org/d.git"))
  (define row-on (lock-row-for '((gui . #t))))
  (define row-off (lock-row-for '((gui . #f))))
  ;; input hash is the eighth value of the row: flipping one flag flips it
  (check-false (equal? (list-ref row-on 7) (list-ref row-off 7)))
  ;; ...while each row carries its own derived flags and the same pin
  (check-equal? (list-ref row-on 5) '((gui . #t)))
  (check-equal? (list-ref row-off 5) '((gui . #f)))
  (check-equal? (list-ref row-on 2) (list-ref row-off 2)))
