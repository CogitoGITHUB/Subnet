#lang racket/base
;; manifest-test.rkt -- the moved-out test submodule of src/store/manifest.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.
;; P-02 (D-055) added the checks that show the round trip keeping the
;; ORDER of the entries and the kind 'spec refusal for a malformed
;; manifest read back from a file.

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

  ;; P-02 / D-055: the round trip keeps the entries AND their order.
  ;; The written order is zeta, alpha, mu -- not alphabetical, and not
  ;; any key a reader could rebuild from -- so the names alone catch a
  ;; reader that sorted, hashed or deduplicated.
  (define ordered
    (list (manifest-entry "zeta" "https://example.org/z.git"
                          "refs/vault/zeta" 30 #f '() #f)
          (manifest-entry "alpha" "https://example.org/a.git"
                          "refs/vault/alpha" 10 20 '("badDate") #t)
          (manifest-entry "mu" "https://example.org/m.git"
                          "refs/vault/mu" 20 #f '() #f)))
  (manifest-write mfile ordered)
  (define ordered-back (manifest-read mfile))
  (check-equal? (map manifest-entry-name ordered-back) '("zeta" "alpha" "mu"))
  (check-equal? ordered-back ordered)
  ;; The whole entry survives the datum, not only the name: the three
  ;; slots that differ between the three entries are read back.
  (check-equal? (manifest-entry-last-fetched (cadr ordered-back)) 20)
  (check-equal? (manifest-entry-fsck-allow (cadr ordered-back)) '("badDate"))
  (check-true (manifest-entry-allow-large? (cadr ordered-back)))
  (check-false (manifest-entry-allow-large? (car ordered-back)))
  ;; Upsert appends and never sorts, so the order still holds after one.
  (check-equal? (map manifest-entry-name
                      (manifest-upsert
                       ordered-back
                       (manifest-entry "beta" "https://example.org/b.git"
                                       "refs/vault/beta" 40 #f '() #f)))
                '("zeta" "alpha" "mu" "beta"))

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

  ;; P-02 / D-055: a malformed manifest raises kind 'spec when it is
  ;; READ, not only when an entry is built. The two checks above are
  ;; the structural half (wrong datum shape, rejected URL), which
  ;; manifest-read itself refuses as 'config; these are the field half,
  ;; which reaches the manifest-entry guard and keeps the guard's kind.
  (define bad-name-file (build-path test-root "bad-name.rktd"))
  (call-with-output-file bad-name-file
    (lambda (out)
      (writeln '(package "Bad Name"
                       "https://example.org/a.git"
                       "refs/vault/Bad Name"
                       1 #f () #f)
               out))
    #:exists 'truncate/replace)
  (define bad-name-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (manifest-read bad-name-file)
      'no-error))
  (check-pred spec-error? bad-name-err)
  (check-equal? (pm-error-exit-code bad-name-err) 3)
  (check-regexp-match #rx"bad package name" (exn-message bad-name-err))

  ;; Same datum shape, a time that is not integer seconds: still 'spec,
  ;; and the message names the offending slot.
  (define bad-added-file (build-path test-root "bad-added.rktd"))
  (call-with-output-file bad-added-file
    (lambda (out)
      (writeln '(package "demo-a"
                       "https://example.org/a.git"
                       "refs/vault/demo-a"
                       "yesterday" #f () #f)
               out))
    #:exists 'truncate/replace)
  (define bad-added-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (manifest-read bad-added-file)
      'no-error))
  (check-pred spec-error? bad-added-err)
  (check-equal? (pm-error-exit-code bad-added-err) 3)
  (check-regexp-match #rx"added must be integer seconds"
                      (exn-message bad-added-err))

  (delete-directory/files test-root))

