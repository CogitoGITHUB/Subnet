#lang racket/base
;; manifest-test.rkt -- the moved-out test submodule of src/store/manifest.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            racket/file
            "../../src/errors/error-type.rkt"
            "../../src/git/git-env.rkt"
            "../../src/spec/spec.rkt"
         "../../src/store/manifest.rkt")

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

