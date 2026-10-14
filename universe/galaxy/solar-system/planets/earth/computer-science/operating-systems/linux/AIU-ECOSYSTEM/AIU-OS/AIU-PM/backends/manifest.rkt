#lang racket/base
;; manifest.rkt -- the vault inventory (docs/VAULT-SPEC.org).
;; manifest.rktd holds ONE entry per package: name, source url,
;; namespace, added and last-fetched times, fsck-allow ids. NO pin:
;; the spec declares the source url, the lockfile holds resolved pins,
;; the manifest holds the inventory (single owner per datum).
;; Times are exact-integer seconds, data only, never decisions (D-015).
;; All writes are atomic tmp+rename appends. Readers re-validate every
;; field (name regex, git-url); a corrupt manifest is kind 'config.

(require racket/contract/base
         racket/file
         "../core/errors.rkt"
         "../core/git-url.rkt"
         "../core/spec.rkt")

(provide
 (struct-out manifest-entry)
 (contract-out
  ;; path-string -> (listof manifest-entry?), missing file reads empty
  [manifest-read (-> path-string? (listof manifest-entry?))]
  ;; path-string (listof manifest-entry?) -> void, atomic tmp+rename
  [manifest-write (-> path-string? (listof manifest-entry?) void?)]
  ;; (listof manifest-entry?) manifest-entry? -> (listof manifest-entry?)
  [manifest-upsert (-> (listof manifest-entry?) manifest-entry?
                       (listof manifest-entry?))]
  ;; (listof manifest-entry?) string? -> (or/c manifest-entry? #f)
  [manifest-get (-> (listof manifest-entry?) string?
                    (or/c manifest-entry? #f))]))

(struct manifest-entry
  (name url namespace added last-fetched fsck-allow allow-large?)
  #:transparent
  #:guard (lambda (name url namespace added last-fetched fsck-allow
                   allow-large? _n)
            (unless (and (string? name)
                         (package-name? (string->symbol name)))
              (raise-pm-error 'spec 'manifest-entry "bad package name"
                              #:fields (list (cons "name" name))))
            (unless (string? url)
              (raise-pm-error 'spec 'manifest-entry "url must be a string"
                              #:fields (list (cons "url" url))))
            (unless (string? namespace)
              (raise-pm-error 'spec 'manifest-entry
                              "namespace must be a string"
                              #:fields (list (cons "namespace" namespace))))
            (unless (exact-integer? added)
              (raise-pm-error 'spec 'manifest-entry
                              "added must be integer seconds"
                              #:fields (list (cons "added" added))))
            (unless (or (not last-fetched)
                        (exact-integer? last-fetched))
              (raise-pm-error 'spec 'manifest-entry
                              "last-fetched must be integer seconds or #f"
                              #:fields (list (cons "last-fetched"
                                                   last-fetched))))
            (unless (and (list? fsck-allow)
                         (andmap string? fsck-allow))
              (raise-pm-error 'spec 'manifest-entry
                              "fsck-allow must be a list of strings"
                              #:fields (list (cons "fsck-allow"
                                                   fsck-allow))))
            (unless (boolean? allow-large?)
              (raise-pm-error 'spec 'manifest-entry
                              "allow-large? must be a boolean"
                              #:fields (list (cons "allow-large?"
                                                   allow-large?))))
            (values name url namespace added last-fetched fsck-allow
                    allow-large?)))
;; name         : string?  D-8 package name
;; url          : string?  source url (validated on read)
;; namespace    : string?  refs/vault/<name> (derived, never passed in)
;; added        : exact-integer?  seconds, data only
;; last-fetched : (or/c exact-integer? #f)  seconds or never, data only
;; fsck-allow   : (listof string?)  per-package message-id opt-outs
;; allow-large? : boolean?  explicit large-blob push flag (backup)

;; any -> manifest-entry, one datum validated or kind 'config
(define (read-entry datum)
  (unless (and (list? datum)
               (= (length datum) 8)
               (eq? (car datum) 'package))
    (raise-pm-error 'config 'manifest-read "bad manifest entry"
                    #:fields (list (cons "datum" (format "~s" datum)))))
  (define parts (cdr datum))
  (with-handlers ([exn:fail:pm? (lambda (e) (raise e))])
    (manifest-entry (list-ref parts 0) (list-ref parts 1)
                    (list-ref parts 2) (list-ref parts 3)
                    (list-ref parts 4) (list-ref parts 5)
                    (list-ref parts 6))))

;; path-string -> (listof manifest-entry?), missing file reads empty
(define (manifest-read path)
  (define p (if (path? path) path (string->path path)))
  (if (not (file-exists? p))
      '()
      (with-handlers ([exn:fail:read?
                       (lambda (e)
                         (raise-pm-error 'config 'manifest-read
                                         "cannot read manifest"
                                         #:fields (list (cons "file"
                                                              (path->string p)))
                                         #:cause e))])
        (define datums (call-with-input-file p read-all-datums))
        (for/list ([d (in-list datums)])
          (define e (read-entry d))
          (with-handlers ([exn:fail:pm?
                           (lambda (bad)
                             (raise-pm-error
                              'config 'manifest-read "bad package url"
                              #:fields (list (cons "name"
                                                   (manifest-entry-name e)))
                              #:cause bad))])
            (check-git-url (manifest-entry-url e)))
          e))))

;; input-port -> (listof any/c), every datum in the file
(define (read-all-datums in)
  (let loop ((acc '()))
    (define d (read in))
    (if (eof-object? d) (reverse acc) (loop (cons d acc)))))

;; manifest-entry -> list, plain data for write
(define (entry->datum e)
  (list 'package
        (manifest-entry-name e) (manifest-entry-url e)
        (manifest-entry-namespace e) (manifest-entry-added e)
        (manifest-entry-last-fetched e) (manifest-entry-fsck-allow e)
        (manifest-entry-allow-large? e)))

;; path-string (listof manifest-entry?) -> void, atomic tmp+rename
(define (manifest-write path entries)
  (define p (if (path? path) path (string->path path)))
  (define tmp (string-append (path->string p) ".tmp"))
  (call-with-output-file tmp
    (lambda (out)
      (for ([e (in-list entries)])
        (writeln (entry->datum e) out)))
    #:exists 'truncate/replace)
  (rename-file-or-directory tmp p #t))

;; (listof manifest-entry?) manifest-entry? -> (listof manifest-entry?)
(define (manifest-upsert entries e)
  (cond [(null? entries) (list e)]
        [(equal? (manifest-entry-name (car entries))
                 (manifest-entry-name e))
         (cons e (cdr entries))]
        [else (cons (car entries) (manifest-upsert (cdr entries) e))]))

;; (listof manifest-entry?) string? -> (or/c manifest-entry? #f)
(define (manifest-get entries name)
  (for/or ([e (in-list entries)])
    (and (equal? (manifest-entry-name e) name) e)))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit)

  (define test-root (make-temporary-directory "pm-manifest~a"))
  (define mfile (build-path test-root "manifest.rktd"))

  ;; Missing file reads empty; round trip preserves every field.
  (check-equal? (manifest-read mfile) '())
  (define e1 (manifest-entry "demo-a" "https://example.org/a.git"
                             "refs/vault/demo-a" 100 200 '("badDate") #f))
  (define e2 (manifest-entry "demo-b" "https://example.org/b.git"
                             "refs/vault/demo-b" 300 #f '() #f))
  (manifest-write mfile (list e1 e2))
  (check-equal? (manifest-read mfile) (list e1 e2))

  ;; Upsert replaces by name, appends when new, preserves order.
  (define e1b (manifest-entry "demo-a" "https://example.org/a.git"
                              "refs/vault/demo-a" 100 400 '() #t))
  (check-equal? (manifest-upsert (list e1 e2) e1b) (list e1b e2))
  (define e3 (manifest-entry "demo-c" "https://example.org/c.git"
                             "refs/vault/demo-c" 500 #f '() #f))
  (check-equal? (manifest-upsert (list e1 e2) e3) (list e1 e2 e3))
  (check-equal? (manifest-get (list e1 e2) "demo-b") e2)
  (check-false (manifest-get (list e1 e2) "missing"))

  ;; Guards reject bad shapes with kind 'spec.
  (check-pred spec-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (manifest-entry "Bad!" "https://example.org/a.git"
                                "refs/vault/Bad!" 1 #f '() #f)
                'no-error))
  (check-pred spec-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (manifest-entry "demo" "https://example.org/a.git"
                                "refs/vault/demo" "yesterday" #f '() #f)
                'no-error))

  ;; Corrupt file and bad URL fail kind 'config on read.
  (call-with-output-file mfile
    (lambda (out) (displayln "(package only-two)" out))
    #:exists 'truncate/replace)
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (manifest-read mfile)
                'no-error))
  (manifest-write mfile (list (manifest-entry
                               "demo" "ext::sh -c true"
                               "refs/vault/demo" 1 #f '() #f)))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (manifest-read mfile)
                'no-error))

  (delete-directory/files test-root))
