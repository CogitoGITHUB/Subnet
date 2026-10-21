#lang racket/base
;; doctor-test.rkt -- the suite for src/entry/doctor-report.rkt, moved out
;; of the module the same way version-test.rkt was (step 14). It checks the
;; two claims that module's header makes, and nothing else:
;;
;;   1. every problem it can see is NAMED -- one finding per planted
;;      problem, each carrying the path doctor looked at and the rule it
;;      broke, so a reader can go and look at the same thing;
;;   2. it WRITES NOTHING -- the tree is identical, file for file and byte
;;      for byte, before and after a run.
;;
;; Fixtures are plain files and directories under the system temp dir. No
;; git is spawned, no network is touched, nothing reads the clock, and
;; each temp dir is removed in a dynamic-wind, so a failing check leaves
;; nothing behind either. The screen is quietened with narration's own
;; test knob: there is no way to turn narration off from a caller, and
;; doctor opening a run of its own would be the write proof (2) exists to
;; catch.

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/string
         "../../src/narration/narration.rkt"
         "../../src/entry/doctor-report.rkt")

(module+ test
  (require rackunit)

  ;; ---------------------------------------------------------------------------
  ;; Fixture helpers

  ;; -> (values path path), a temp dir and the state root inside it. Two
  ;; values because dynamic-wind removes the temp dir, not the leaf.
  (define (new-state)
    (define tmp (make-temporary-directory "pm-doctor~a"))
    (values tmp (build-path tmp "state")))

  ;; path string -> void, write TEXT at FILE, parents created
  (define (write-text! file text)
    (make-directory* (or (path-only file) file))
    (call-with-output-file file
      (lambda (out) (display text out))
      #:exists 'truncate/replace))

  ;; path -> (listof path), every FILE under DIR, directories walked and
  ;; links treated as the files they are.
  (define (tree-files dir)
    (sort (append*
            (for/list ([entry (in-list (directory-list dir))])
              (define full (build-path dir entry))
              (if (and (directory-exists? full) (not (link-exists? full)))
                  (tree-files full)
                  (list full))))
          path<?))

  ;; path -> (listof (cons string bytes)), the tree with every file's
  ;; CONTENT beside it: this is the snapshot proof (2) compares against
  ;; itself. Bytes, not a digest -- the fixture files are a handful of
  ;; bytes each, and a digest would only be a way of losing a failure.
  (define (tree-snapshot root)
    (for/list ([f (in-list (tree-files root))])
      (cons (path->string f) (file->bytes f))))

  ;; The lockfile text one pin takes (D-004: nine fields per row). The
  ;; commit is forty hex characters because git-id? says so, and the URL
  ;; is the same shape cli-test.rkt uses -- no fetch is ever attempted,
  ;; doctor reads the file and nothing else.
  (define pinned-lock
    (string-append
     "(lockfile (format-version 2)\n"
     "  (pins ((demo \"1.0.0\""
     " \"1111111111111111111111111111111111111111\""
     " \"https://example.org/demo.git\""
     " lts () \"spec-hash\" \"input-hash\" ()))))\n"))

  ;; The same file with nothing pinned yet: valid, and empty.
  ;; The lock's pins field holds ONE value -- the list of entries -- so an
  ;; empty lock is (pins ()), the shape write-lockfile emits.
  (define empty-lock "(lockfile (format-version 2) (pins ()))\n")

  ;; ---------------------------------------------------------------------------
  ;; PROOFS 1 and 2: a state root with planted problems, then the proof
  ;; that reporting them changed nothing.

  (define-values (planted-tmp planted) (new-state))
  (dynamic-wind
    void
    (lambda ()
      ;; A profile root holding a profile-1 that is a FILE where a
      ;; generation directory belongs, and no live link beside it.
      (make-directory* (build-path planted "profile"))
      (write-text! (build-path planted "profile" "profile-1")
                   "not a generation\n")

      ;; A versioned store directory still holding .pm-incomplete: a
      ;; materialisation that died part-way.
      (define dead-store
        (build-path planted "store" "demo" "lts" "1.0.0-deadbeef1234"))
      (make-directory* dead-store)
      (write-text! (build-path dead-store ".pm-incomplete") "run 7 died here\n")

      ;; A lockfile pinning demo, and a vault holding no ref for it: the
      ;; pin cannot be honoured.
      (write-text! (build-path planted "pm.lock") pinned-lock)
      (make-directory* (build-path planted "vault.git" "objects"))

      ;; The lock record a dead run left beside the vault, owner record
      ;; and all. No manifest at all, which is its own finding.
      (write-text! (build-path planted "vault.lock") "")
      (write-text! (build-path planted "vault.lock.owner") "run 7\n")

      (define before (tree-snapshot planted))
      (check-true (pair? before))

      ;; #:vault is passed for a reason: profile, store, lockfile and
      ;; manifest default to leaves under the state root, but the vault
      ;; default is the SHARED one from documents.rkt. Leaving it alone
      ;; here would point the vault checks at the real user vault, and a
      ;; test has no business reading that.
      (define findings
        (parameterize ([verbose-screen? #f])
          (doctor-findings #:state-root planted
                           #:vault (build-path planted "vault.git"))))

      ;; PROOF 1: every planted problem is named, by kind.
      (check-equal?
       (sort (map doctor-finding-kind findings) symbol<?)
       '(manifest-absent
         profile-generation-missing
         profile-link-missing
         store-marker-stuck
         vault-clone-missing
         vault-lock-left-behind))

      ;; The store finding names the exact directory that is stuck, which
      ;; is the whole point of a report: the reader goes and looks at the
      ;; same thing doctor looked at.
      (check-equal?
       (doctor-finding-path
        (findf (lambda (f) (eq? 'store-marker-stuck (doctor-finding-kind f)))
               findings))
       (path->string dead-store))

      ;; Every finding carries a path under the root that was checked and
      ;; something to do about it.
      (for ([f (in-list findings)])
        (check-true (doctor-finding? f))
        (check-true (string-prefix? (doctor-finding-path f)
                                    (path->string planted)))
        (check-true (string? (doctor-finding-detail f))))

      ;; The levels come from FAILING-KINDS as data: four of these six
      ;; findings are FAIL, the two absent-and-left-behind ones are WARN.
      (check-equal? (doctor-fail-count findings) 4)

      ;; The one printer gets the same document, paths included.
      (check-true (regexp-match?
                   (regexp (regexp-quote (path->string dead-store)))
                   (string-join (doctor-report-text findings) "\n")))

      ;; PROOF 2: it wrote nothing. The tree after the run is the tree
      ;; before it, every file and its hash.
      (check-equal? (tree-snapshot planted) before))
    (lambda () (delete-directory/files planted-tmp)))

  ;; ---------------------------------------------------------------------------
  ;; The same root with every planted problem repaired: nothing to report,
  ;; and the document says clean rather than count zero by luck.

  (define-values (healthy-tmp healthy) (new-state))
  (dynamic-wind
    void
    (lambda ()
      (make-directory* (build-path healthy "profile" "profile-1"))
      (make-file-or-directory-link (build-path healthy "profile" "profile-1")
                                   (build-path healthy "profile" "profile"))
      (write-text! (build-path healthy "pm.lock") empty-lock)
      (write-text! (build-path healthy "manifest.rktd") "")
      (make-directory* (build-path healthy "vault.git"))

      (define findings
        (parameterize ([verbose-screen? #f])
          (doctor-findings #:state-root healthy
                           #:vault (build-path healthy "vault.git"))))
      (check-equal? findings '())

      (define doc (doctor-document findings))
      (check-equal? (hash-ref doc 'count) 0)
      (check-equal? (hash-ref doc 'clean) #t)
      (check-equal? (hash-ref doc 'name) "doctor")
      (check-regexp-match #rx"nothing was changed"
                          (last (doctor-report-text findings))))
    (lambda () (delete-directory/files healthy-tmp))))
