#lang racket/base
;; lock.rkt -- lockfile read and write (atomic, sorted). No network.
;; Format (D-004): (lockfile (format-version 1) (pins (ENTRY ...)))
;; with ENTRY = (NAME VERSION COMMIT URL), sorted by NAME for diffs.

(require racket/contract/base
         racket/file
         racket/port
         "errors.rkt"
         "version.rkt"
         "git-id.rkt"
         "git-url.rkt"
         "spec.rkt")

(provide
 (struct-out lock-entry)
 (struct-out lockfile)
 (contract-out
  ;; path-string -> lockfile, bad input raises kind 'spec with srcloc
  [read-lockfile (-> path-string? lockfile?)]
  ;; path-string lockfile -> void, atomic write with sorted entries
  [write-lockfile (-> path-string? lockfile? void?)]))

;; ---------------------------------------------------------------------------
;; Data

(struct lock-entry (name version commit url)
  #:transparent
  #:guard (lambda (name version commit url _n)
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
            (values name version commit url)))
;; name    : package-name?  D-8
;; version : version?       exact pin, matches spec equality
;; commit  : string?        full commit id the version resolves to
;; url     : string?        git URL (scheme checked on read)

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

;; syntax -> lock-entry, one (NAME VERSION COMMIT URL) datum
(define (lock-read-entry item)
  (define parts (syntax->list item))
  (if (not (and parts (= (length parts) 4)))
      (lock-fail item "pin must be (NAME VERSION COMMIT URL)")
      (lock-entry (lock-convert-name (car parts))
                  (lock-convert-version (cadr parts))
                  (lock-convert-commit (caddr parts))
                  (lock-convert-url (cadddr parts)))))

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

;; syntax syntax -> lockfile
(define (read-lockfile-checked version-form pins-form)
  (define version-arg (lock-one-arg version-form 'format-version))
  (define version-value (syntax->datum version-arg))
  (if (not (and (exact-integer? version-value) (= version-value 1)))
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
                      symbol<?
                      #:key lock-entry-name))))

;; ---------------------------------------------------------------------------
;; Writing (atomic, sorted for meaningful diffs per D-6)

;; path-string lockfile -> void, temp file in place plus rename (F-3)
(define (write-lockfile path lf)
  (define sorted (sort (lockfile-entries lf) symbol<?
                       #:key lock-entry-name))
  (call-with-atomic-output-file path
    (lambda (out tmp)
      (write `(lockfile (format-version 1)
                        (pins ,(for/list ([e (in-list sorted)])
                                 (list (lock-entry-name e)
                                       (version->string
                                        (lock-entry-version e))
                                       (lock-entry-commit e)
                                       (lock-entry-url e)))))
             out)
      (newline out))))

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
                                      "https://example.org/x.git")))
             'spec)
  (check-eq? (lock-kind (lambda ()
                          (lock-entry 'demo (string->version "1.0")
                                      "xyz"
                                      "https://example.org/x.git")))
             'spec)
  (check-eq? (lock-kind (lambda () (lockfile '(1 2)))) 'spec)

  ;; Round trip preserves content.
  (define round-dir (make-temporary-directory "pm-lock~a"))
  (define round-path (build-path round-dir "lockfile.rktd"))
  (define round-entry
    (lock-entry 'demo (string->version "2.9.1")
                "9edb3f66fd807b096b48283debdcddccfea34bad"
                "https://example.org/demo.git"))
  (write-lockfile round-path (lockfile (list round-entry)))
  (define round-back (read-lockfile round-path))
  (check-true (lockfile? round-back))
  (check-equal? (map lock-entry-name (lockfile-entries round-back))
                '(demo))
  (check-equal? (version->string
                 (lock-entry-version (car (lockfile-entries round-back))))
                "2.9.1")

  ;; The writer sorts by name whatever the input order.
  (define sort-entry-a
    (lock-entry 'aaa (string->version "1.0") (make-string 40 #\a)
                "https://example.org/a.git"))
  (define sort-entry-z
    (lock-entry 'zzz (string->version "1.0") (make-string 40 #\f)
                "https://example.org/z.git"))
  (write-lockfile round-path (lockfile (list sort-entry-z sort-entry-a)))
  (check-equal? (map lock-entry-name
                     (lockfile-entries (read-lockfile round-path)))
                '(aaa zzz))
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
                       "(lockfile (format-version 2) (pins ()))"))
  (check-regexp-match #rx"not a commit id"
                      (lock-message-for
                       (string-append
                        "(lockfile (format-version 1) (pins "
                        "((demo \"1.0\" \"xyz\" \"https://example.org/d.git\"))))")))
  (check-regexp-match #rx"rejected git URL"
                      (lock-message-for
                       (string-append
                        "(lockfile (format-version 1) (pins "
                        "((demo \"1.0\" \""
                        (make-string 40 #\a)
                        "\" \"ext::sh -c true\"))))")))
  (check-regexp-match #rx"cannot read lockfile"
                      (lock-message-for "(lockfile (format-version 1)"))
  (check-regexp-match #rx"empty lockfile" (lock-message-for ""))
  (check-regexp-match #rx"trailing data"
                      (lock-message-for
                       "(lockfile (format-version 1) (pins ())) 42"))
  (check-pred spec-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (read-lockfile "/nonexistent-pm-dir/lockfile.rktd")
                'no-error)))
