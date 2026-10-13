#lang racket/base
;; query.rkt -- answer why, owner and verify. Read-only (E-17): no
;; spawn beyond vault reads, no writes anywhere, no locks. Data plus
;; rendered text per question; kind 'config for a package or path the
;; inputs do not know. Ownership parses store-layout link targets
;; (mirrors activate.rkt generation-owner-names); dev checkouts name
;; nothing until E-19.

(require racket/contract/base
         racket/file
         racket/list
         racket/path
         racket/string
         "manifest.rkt"
         "vault.rkt"
         "../core/errors.rkt"
         "../core/lock.rkt"
         "../core/plan.rkt"
         "../core/version.rkt"
         "../core/verbose.rkt")

(provide
 (contract-out
  ;; lockentries manifest-entries string -> why-datum, spec/slot/pin
  [query-why (-> (listof lock-entry?) (listof manifest-entry?) string?
                 (list/c string? string? string? list? string? string?))]
  ;; why-datum -> string, one info line
  [why->text (-> (list/c string? string? string? list? string? string?)
                 string?)]
  ;; path-string string -> claim, owner and target or free/unknown
  [query-owner (-> path-string? string?
                   (or/c #f (list/c (or/c #f string?) string?)))]
  ;; claim string -> string, one info line
  [owner->text (-> (or/c #f (list/c (or/c #f string?) string?)) string?
                   string?)]
  ;; vault current name pin -> verify-datum, tree against its pin
  [query-verify (-> path-string? path-string? string? string?
                    (list/c string? boolean? (listof string?)))]
  ;; verify-datum -> string, one info line
  [verify->text (-> (list/c string? boolean? (listof string?)) string?)]
  ;; vault current name pin -> void, G-03 refuses a tampered tree
  [verify-tree! (-> path-string? path-string? string? string? void?)]
  ;; vault name url pin -> void, G-03 refuses a moved source
  [verify-source! (-> path-string? string? string? string? void?)]))

;; string -> string, store-layout owner segment or #f (dev trees: E-19)
(define (target-owner target)
  (define m (regexp-match #rx"/store/([^/]+)/" target))
  (and m (second m)))

;; lockentries manifest-entries string -> why-datum
(define (query-why locks manifests name)
  ;; D-036: a read-only query still narrates WHY it looked where it
  ;; looked, so "why is this installed" has an answer on the record and
  ;; not just on the screen.
  (with-op 'query name "the user asked why this package is present"
           #:how "lockfile first, then the manifest"
           (lambda ()
             (step 'query "lockfile"
                   "the lockfile is authoritative for what is pinned")
             (define lock-hit
               (for/or ([e (in-list locks)])
                 (and (equal? (symbol->string (lock-entry-name e)) name) e)))
             (unless lock-hit
               (skip 'query name "no lockfile entry names this package")
               (raise-pm-error 'config 'query-why "package not in lockfile"
                               #:fields `(("package" . ,name))))
             (step 'query "manifest"
                   "the manifest says where the source came from")
             (define manifest-hit
               (for/or ([e (in-list manifests)])
                 (and (equal? (manifest-entry-name e) name) e)))
             (unless manifest-hit
               (skip 'query name "no manifest entry names this package")
               (raise-pm-error 'config 'query-why "package not in manifest"
                               #:fields `(("package" . ,name))))
             (decide 'query name "both records agree, so the answer is certain"
                     #:chosen (manifest-entry-url manifest-hit)
                     #:alternatives (list "lockfile only" "manifest only"))
             (list name
                   (version->string (lock-entry-version lock-hit))
                   (symbol->string (lock-entry-slot lock-hit))
                   (lock-entry-flags lock-hit)
                   (lock-entry-commit lock-hit)
                   (manifest-entry-url manifest-hit)))))

;; why-datum -> string
(define (why->text w)
  (format "~a ~a [~a] flags=~s pin=~a url=~a"
          (first w) (second w) (third w)
          (fourth w) (fifth w) (sixth w)))

;; path-string string -> claim. The current generation is walked for
;; links; rel must be relative and inside. Free paths answer #f.
(define (query-owner profile-root rel)
  (define p (string->path rel))
  (when (or (absolute-path? p) (member 'up (explode-path p)))
    (raise-pm-error 'config 'query-owner "path escapes the profile"
                    #:fields `(("path" . ,rel))))
  (define link (build-path profile-root "profile"))
  (unless (link-exists? link)
    (raise-pm-error 'config 'query-owner "no active profile"))
  ;; G-04: the ledger answers first. It is the record the generation
  ;; was built from; the tree walk below is only the fallback for
  ;; generations predating ledgers.
  (define from-ledger
    (with-handlers ([(lambda (e) #t) (lambda (e) #f)])
      (define ledger
        (call-with-input-file (build-path (resolve-path link) "ledger.rktd")
          read))
      (and (pair? ledger)
           (eq? (car ledger) 'ledger)
           (for/or ([t (in-list (cdr ledger))])
             (and (list? t)
                  (= 3 (length t))
                  (equal? (third t) rel)
                  (list (first t) (second t)))))))
  (or from-ledger
    (let walk ([dir (resolve-path link)] [acc #f])
      (if acc
          acc
          (for/fold ([hit #f]) ([q (in-list (directory-list dir))])
            (or hit
                (let ([full (build-path dir q)])
                  (cond [(link-exists? full)
                         (define target
                           (with-handlers ([exn:fail? (lambda (e) #f)])
                             (path->string (resolve-path full))))
                         (define here (path->string (find-relative-path
                                                     (resolve-path link) full)))
                         (and target
                              (equal? here rel)
                              (list (target-owner target) target))]
                        [(directory-exists? full) (walk full #f)]
                        [else #f]))))))))

;; claim string -> string
(define (owner->text claim rel)
  (cond [(not claim) (format "~a is free" rel)]
        [(not (first claim))
         (format "~a claimed by an unnamed tree (-> ~a)" rel (second claim))]
        [else (format "~a owned by ~a" rel (first claim))]))

;; path-string -> (listof list), (rel kind payload) file inventory
(define (tree-inventory dir)
  (define (walk base rel)
    (for/fold ([out '()]) ([q (in-list (directory-list (build-path base rel)))])
      (define r (if (string=? rel ".")
                    (path->string q)
                    (string-append rel "/" (path->string q))))
      (define full (build-path base r))
      (cond [(link-exists? full)
             (define target
               (with-handlers ([exn:fail? (lambda (e) #f)])
                 (path->string (resolve-path full))))
             (cons (list r 'link (or target "dangling")) out)]
            [(directory-exists? full) (append (walk base r) out)]
            [(file-exists? full)
             (cons (list r 'file (file->string full)) out)]
            [else out])))
  (walk (if (path? dir) (path->string dir) dir) "."))

;; vault current name pin -> verify-datum. The pin is exported to a
;; temp staging dir and compared file by file; only equal bytes pass.
(define (query-verify vault-root current name pin)
  (unless (directory-exists? current)
    (raise-pm-error 'config 'query-verify "current tree missing"
                    #:fields `(("dir" . ,(if (path? current)
                                             (path->string current)
                                             current)))))
  (define stage (make-temporary-directory "pm-verify~a"))
  (define tree (build-path stage "tree"))
  (make-directory tree)
  (define diffs
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (delete-directory/files stage)
                       (raise e))])
      (vault-export-commit vault-root name pin tree)
      (define want
        (for/hash ([f (in-list (tree-inventory (path->string tree)))])
          (values (first f) (rest f))))
      (define diffs-rev
        (for/fold ([out '()]) ([f (in-list (tree-inventory current))])
          (define hit (hash-ref want (first f) #f))
          (cond [(not hit) (cons (string-append "local-only: " (first f)) out)]
                [(not (equal? hit (rest f)))
                 (cons (string-append "changed: " (first f)) out)]
                [else out])))
      (define have (map first (tree-inventory current)))
      (for/fold ([out diffs-rev]) ([f (in-list (tree-inventory
                                                (path->string tree)))])
        (if (member (first f) have)
            out
            (cons (string-append "vault-only: " (first f)) out)))))
  (delete-directory/files stage)
  (list name (null? diffs) diffs))

;; verify-datum -> string
(define (verify->text v)
  (if (second v)
      (format "~a: verified" (first v))
      (format "~a: MISMATCH ~a" (first v) (string-join (third v) "; "))))

;; G-03: verify as its own stage. query-verify REPORTS diffs; these two
;; REFUSE with kind 'verify (exit 6). Source first, then tree: a moved
;; source means the pin no longer names what was reviewed, and a
;; changed tree means the bytes are not what the pin says.

;; path-string path-string string string -> void
(define (verify-tree! vault-root current name pin)
  (with-op 'verify (format "~a at ~a" name pin)
           "the live tree must be byte-identical to its pin"
           #:inputs (list name pin)
           (lambda ()
             (define v (query-verify vault-root current name pin))
             (if (second v)
                 (step 'verify "match"
                       "every byte of the tree matches the pinned commit")
                 (begin
                   (skip 'verify (format "~a ~a" name pin)
                         (string-append "the tree differs: "
                                        (string-join (third v) "; ")))
                   (raise-pm-error 'verify 'verify-tree!
                                   (format "~a: tree does not match pin ~a"
                                           name pin)
                                   #:fields `(("diffs" . ,(string-join
                                                            (third v) "; ")))))))))

;; path-string string string string -> void
(define (verify-source! vault-root name url pin)
  (with-op 'verify name "the source must still resolve to the pinned commit"
           #:inputs (list url pin)
           (lambda ()
             (define remote
               (vault-add-result-pin
                (vault-add vault-root name url #:fsck-allow '())))
             (if (equal? remote pin)
                 (step 'verify "pin"
                       "the source resolves to exactly the recorded commit")
                 (begin
                   (skip 'verify name
                         (string-append "the source moved from " pin
                                        " to " remote))
                   (raise-pm-error 'verify 'verify-source!
                                   (format "~a: source moved from ~a to ~a"
                                           name pin remote)
                                   #:fields `(("want" . ,pin)
                                              ("got" . ,remote))))))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/path
           "git.rkt"
           "manifest.rkt"
           "run.rkt"
           "../core/errors.rkt"
           "../core/git-url.rkt"
           "../core/lock.rkt"
           "../core/version.rkt")

  ;; All fixtures are synthetic (T-10) under one temp root: a lock plus
  ;; manifest entry, a profile generation with links, a vault holding
  ;; one pin plus a current tree to compare. Nothing leaves temp.
  (define test-root (make-temporary-directory "pm-query~a"))
  (define test-lock
    (list (lock-entry 'pkg-a (string->version "1.0")
                      (make-string 40 #\a)
                      "https://example.org/a.git"
                      'default '((gui . #t)) "s" "i" '())))
  (define test-manifest
    (list (manifest-entry "pkg-a" "https://example.org/a.git"
                          "refs/vault/pkg-a" 1 #f '() #f)))

  ;; why names spec, slot, flags and pin; unknown names refuse.
  (define why (query-why test-lock test-manifest "pkg-a"))
  (check-equal? (list (first why) (second why) (third why))
                '("pkg-a" "1.0" "default"))
  (check-equal? (fourth why) '((gui . #t)))
  (check-regexp-match #rx"pkg-a 1.0 \\[default\\]" (why->text why))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (query-why test-lock test-manifest "pkg-nope")
                'no-error))

  ;; owner reports the claim on a taken path, nothing on a free one.
  (define store-a (build-path test-root "store" "pkg-a" "default" "1.0-x"))
  (make-directory* (build-path store-a "bin"))
  (call-with-output-file (build-path store-a "bin" "prog")
    (lambda (out) (display "x" out)))
  (define prof (build-path test-root "profile"))
  (define gen1 (build-path prof "profile-001"))
  (make-directory* (build-path gen1 "bin"))
  (make-file-or-directory-link (path->string (build-path store-a "bin" "prog"))
                               (build-path gen1 "bin" "prog"))
  (make-file-or-directory-link (path->string gen1)
                               (build-path prof "profile"))
  (define claim (query-owner (path->string prof) "bin/prog"))
  (check-equal? (first claim) "pkg-a")
  (check-equal? (second claim)
                (path->string (build-path store-a "bin" "prog")))
  (check-regexp-match #rx"owned by pkg-a"
                      (owner->text claim "bin/prog"))
  (check-false (query-owner (path->string prof) "bin/free"))
  (check-equal? (owner->text #f "bin/free") "bin/free is free")
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (query-owner (path->string prof) "/abs/path")
                'no-error))

  ;; G-04: with a ledger present, the ledger answers even when the tree
  ;; has diverged. Repoint the link after the fact; the record still
  ;; names the original owner.
  (define gen2 (build-path prof "profile-002"))
  (make-directory* (build-path gen2 "bin"))
  (define store-b (build-path test-root "store" "pkg-b" "default" "1.0-x"))
  (make-directory* (build-path store-b "bin"))
  (call-with-output-file (build-path store-b "bin" "prog")
    (lambda (out) (display "y" out)))
  (make-file-or-directory-link (path->string (build-path store-a "bin" "prog"))
                               (build-path gen2 "bin" "prog"))
  (call-with-output-file (build-path gen2 "ledger.rktd")
    (lambda (out)
      ;; One triple per owned path: (ledger (NAME DIR REL) ...), the
      ;; same shape build-generation! writes.
      (write `(ledger ("pkg-a" ,(path->string (build-path store-a "bin" "prog"))
                                 "bin/prog"))
             out)))
  (delete-file (build-path prof "profile"))
  (make-file-or-directory-link (path->string gen2)
                               (build-path prof "profile"))
  ;; Diverge the tree: the link now points at pkg-b, but the ledger
  ;; still says pkg-a, and the ledger wins.
  (delete-file (build-path gen2 "bin" "prog"))
  (make-file-or-directory-link (path->string (build-path store-b "bin" "prog"))
                               (build-path gen2 "bin" "prog"))
  (define ledged (query-owner (path->string prof) "bin/prog"))
  (check-equal? (first ledged) "pkg-a")
  (check-equal? (second ledged)
                (path->string (build-path store-a "bin" "prog")))

  ;; verify compares the current tree against its pin, byte by byte.
  (define up (build-path test-root "upstream"))
  (make-directory up)
  (define home (build-path test-root "home"))
  (make-directory home)
  (define (qgit dir . args)
    (define res
      (run-command (git-executable-path) args
                   #:cwd (path->string dir)
                   #:kind 'fetch #:operation "query-fixture"
                   #:env `(("GIT_AUTHOR_NAME" . "t")
                            ("GIT_AUTHOR_EMAIL" . "t@t")
                            ("GIT_COMMITTER_NAME" . "t")
                            ("GIT_COMMITTER_EMAIL" . "t@t")
                            ("HOME" . ,(path->string home))
                            ("GIT_CONFIG_NOSYSTEM" . "1"))))
    (unless (zero? (run-result-exit res))
      (error 'query-fixture "git failed: ~a" args))
    res)
  (qgit up "init" "-b" "main" ".")
  (call-with-output-file (build-path up "f.txt")
    (lambda (out) (displayln "F" out)))
  (qgit up "add" "-A")
  (qgit up "commit" "-qm" "init")
  (define vg (build-path test-root "vault" "vault.git"))
  (make-directory* (build-path test-root "vault"))
  (vault-init vg)
  (define vpin
    (parameterize ([current-allow-file-urls #t])
      (vault-add-result-pin
       (vault-add vg "pkg-a" (string-append "file://" (path->string up))))))
  (define cur (build-path test-root "current"))
  (make-directory cur)
  (vault-export-commit vg "pkg-a" vpin cur)
  (check-equal? (query-verify (path->string vg) (path->string cur)
                              "pkg-a" vpin)
                (list "pkg-a" #t '()))
  (call-with-output-file (build-path cur "f.txt")
    (lambda (out) (display "changed" out))
    #:exists 'truncate/replace)
  (define bad (query-verify (path->string vg) (path->string cur)
                            "pkg-a" vpin))
  (check-false (second bad))
  (check-not-false (member "changed: f.txt" (third bad)))
  (check-regexp-match #rx"MISMATCH" (verify->text bad))
  (check-equal? (verify->text (list "pkg-a" #t '())) "pkg-a: verified")
  ;; G-03: the stage refuses. A clean tree passes silently; a tampered
  ;; one raises kind 'verify, which exits 6.
  (define cur2 (build-path test-root "current2"))
  (make-directory cur2)
  (vault-export-commit vg "pkg-a" vpin cur2)
  (check-true (with-handlers ([exn:fail:pm? (lambda (e) #f)])
                (verify-tree! (path->string vg) (path->string cur2)
                              "pkg-a" vpin)
                #t))
  (call-with-output-file (build-path cur2 "f.txt")
    (lambda (out) (display "tampered" out))
    #:exists 'truncate/replace)
  (define tampered-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (verify-tree! (path->string vg) (path->string cur2) "pkg-a" vpin)
      'no-error))
  (check-pred verify-error? tampered-err)
  (check-equal? (pm-error-exit-code tampered-err) 6)
  ;; The source still resolves to the pin, so the source stage passes;
  ;; move upstream one commit and it refuses too.
  (parameterize ([current-allow-file-urls #t])
    (check-true (with-handlers ([exn:fail:pm? (lambda (e) #f)])
                  (verify-source! (path->string vg) "pkg-a"
                                  (string-append "file://" (path->string up))
                                  vpin)
                  #t)))
  (call-with-output-file (build-path up "g.txt")
    (lambda (out) (displayln "G" out)))
  (qgit up "add" "-A")
  (qgit up "commit" "-qm" "second")
  (define moved-err
    (parameterize ([current-allow-file-urls #t])
      (with-handlers ([exn:fail:pm? (lambda (e) e)])
        (verify-source! (path->string vg) "pkg-a"
                        (string-append "file://" (path->string up)) vpin)
        'no-error)))
  (check-pred verify-error? moved-err)
  (check-equal? (pm-error-exit-code moved-err) 6)
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (query-verify (path->string vg) "/nonexistent-pm-query"
                              "pkg-a" vpin)
                'no-error))
  (delete-directory/files test-root))
