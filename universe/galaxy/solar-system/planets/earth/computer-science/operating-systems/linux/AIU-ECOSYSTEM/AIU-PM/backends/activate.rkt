#lang racket/base
;; activate.rkt -- own the profile: generations plus the atomic swap
;; (ENGINE.org backends/activate.rkt, SPEC-NEUTRAL section 4, E-13).
;;
;; Generations are profile-NNN/ dirs holding REAL subdirectories with
;; symlinks to files inside each package's current tree (absolute
;; targets; a moved store shows as stale links, which pm status
;; reports). Activate validates everything first, builds the next
;; generation, then flips the profile link with store.rkt's atomic
;; swap: a conflict fails closed with kind 'activate (exit 9) before
;; anything changes. No precedence rules, no last-wins. E-15 lives
;; here too: rollback repoints at a numbered generation, remove builds
;; a generation minus one package (never touching store dirs, D-024),
;; hold pins slots in profile/holds.rktd. The writer lock is a
;; caller (CLI) concern per E-12c, not this module's. Ownership comes
;; in explicitly as (name dir rels) triples; the manifest will supply
;; them from E-14 on.

(require racket/contract/base
         racket/file
         racket/list
         racket/path
         racket/string
         "store.rkt"
         "../core/errors.rkt"
         "../core/verbose.rkt")

(provide
 (contract-out
  ;; (listof entry) path-string -> path, next generation, profile flips
  [profile-activate (->* ((listof (list/c string? path-string?
                                          (listof string?)))
                          path-string?)
                         (#:interface string?
                          #:specs (listof string?)
                          #:lock (or/c string? #f))
                         path?)]
  ;; path-string -> (listof (gen provenance)), oldest first; provenance
  ;; is #f for generations predating it, else (run-id interface specs lock)
  [profile-generations (-> path-string?
                           (listof (list/c path? (or/c #f (list/c (or/c string? #f)
                                                                  string?
                                                                  (listof string?)
                                                                  (or/c string? #f))))))]
  ;; generation dir -> provenance or #f, never raises
  [generation-provenance (-> path-string?
                             (or/c #f (list/c (or/c string? #f)
                                              string?
                                              (listof string?)
                                              (or/c string? #f))))]
  ;; path-string exact-integer -> path, repoint profile at generation N
  [profile-rollback (-> path-string? exact-integer? path?)]
  ;; path-string string (listof entry) -> path, generation minus one
  [profile-remove (-> path-string? string?
                      (listof (list/c string? path-string?
                                      (listof string?)))
                      path?)]
  ;; path-string string string -> void, pin a slot against updates
  [profile-hold (-> path-string? string? string? void?)]
  ;; path-string string string -> void, release a slot pin
  [profile-unhold (-> path-string? string? string? void?)]
  ;; path-string string string -> boolean, is the slot pinned
  [profile-held? (-> path-string? string? string? boolean?)]
  ;; path-string -> path, where the profile link points today
  [current-generation (-> path-string? path?)]
  ;; path-string -> (listof (name slot)), absent reads as none held
  [read-holds (-> path-string? (listof (list/c string? string?)))]))

;; exact-integer -> string, profile-001 style, sortable as text
(define (gen-dir-name n)
  (define digits (number->string n))
  (string-append "profile-"
                 (make-string (max 0 (- 3 (string-length digits))) #\0)
                 digits))

;; path -> exact-integer, one past the highest generation number
(define (next-gen-number profile-root)
  (define nums
    (for/list ([g (in-list (profile-generations profile-root))])
      (define p (first g))
      (define m (regexp-match #rx"profile-([0-9]+)$"
                              (path->string (file-name-from-path p))))
      (string->number (second m))))
  (if (null? nums) 1 (+ 1 (apply max nums))))

;; path-string -> (listof path), existing generations oldest first
(define (profile-generations profile-root)
  (if (not (directory-exists? profile-root))
      '()
      (sort (for/list ([p (in-list (directory-list profile-root))]
                       #:when (regexp-match? #rx"^profile-[0-9]+$"
                                             (path->string p)))
              (define gen (build-path profile-root p))
              (list gen (generation-provenance (path->string gen))))
            (lambda (a b) (path<? (first a) (first b))))))

;; path-string -> provenance or #f, never raises: a generation without
;; a provenance file predates provenance, and that is absence, not error
(define (generation-provenance gen)
  (with-handlers ([(lambda (e) #t) (lambda (e) #f)])
    (define datum
      (call-with-input-file (build-path (if (path? gen) gen (string->path gen))
                                        "provenance.rktd")
        read))
    (and (pair? datum)
         (eq? (car datum) 'provenance)
         (pair? (cdr datum))
         (let ([p (cadr datum)])
           (and (list? p)
                (= 4 (length p))
                p)))))

;; string -> void, single-segment package names only
(define (check-entry-name name)
  (unless (and (string? name)
               (not (string=? name ""))
               (not (string-contains? name "/")))
    (raise-pm-error 'config 'profile-activate "bad package name"
                    #:fields `(("name" . ,name)))))

;; string string -> void, rels stay inside their package dir
(define (check-entry-rel name rel)
  (define p (string->path rel))
  (when (or (absolute-path? p) (member 'up (explode-path p)))
    (raise-pm-error 'config 'profile-activate "rel escapes the package"
                    #:fields `(("package" . ,name) ("rel" . ,rel)))))

;; string path-string (listof string) -> (listof list), checked triples
(define (entry-triples name dir rels)
  (check-entry-name name)
  (unless (directory-exists? dir)
    (raise-pm-error 'activate 'profile-activate "package dir missing"
                    #:fields `(("package" . ,name)
                                ("dir" . ,(if (path? dir)
                                              (path->string dir)
                                              dir)))))
  (for/list ([rel (in-list rels)])
    (check-entry-rel name rel)
    (define target (build-path dir rel))
    (unless (or (file-exists? target) (directory-exists? target))
      (raise-pm-error 'activate 'profile-activate "activation target missing"
                      #:fields `(("package" . ,name) ("rel" . ,rel))))
    (list name (path->string target) rel)))

;; (listof entry) -> (listof list), every conflict fails before change
(define (check-conflicts triples)
  (define seen (make-hash))
  (for ([t (in-list triples)])
    (define rel (third t))
    (define prev (hash-ref seen rel #f))
    (cond [(not prev) (hash-set! seen rel t)]
          [(equal? (first prev) (first t)) (void)]
          [else
           (raise-pm-error
            'activate 'profile-activate "file conflict, nothing changed"
            #:fields `(("file" . ,rel)
                         ("owned-by" . ,(first prev))
                         ("claimed-by" . ,(first t)))
            #:hint "deactivate one package")])))

;; (listof entry) path-string -> void, one generation dir of links
(define (build-generation! triples gen)
  (define done (make-hash))
  (with-handlers ([exn:fail:filesystem?
                   (lambda (e)
                     (raise-pm-error 'activate 'profile-activate
                                     "cannot build generation"
                                     #:fields `(("dir" . ,(path->string gen)))
                                     #:cause e))])
    (for ([d (in-list '("bin" "lib" "include" "share" "libexec" "man"))])
      (make-directory* (build-path gen d)))
    (for ([t (in-list triples)])
      (define rel (third t))
      (unless (hash-ref done rel #f)
        (hash-set! done rel #t)
        (define link (build-path gen rel))
        (make-directory* (or (path-only link) gen))
        (make-file-or-directory-link (second t) link)))
    ;; G-04: the generation records the ledger it was built from. One
    ;; file, one triple per owned path, so query-owner answers from the
    ;; record instead of re-walking the tree.
    (call-with-output-file (build-path gen "ledger.rktd")
      (lambda (out)
        (write (cons 'ledger
                     (map (lambda (t)
                            (define d (second t))
                            (list (first t)
                                  (if (path? d) (path->string d) d)
                                  (third t)))
                          triples))
               out))
      #:exists 'truncate/replace)))

;; (listof entry) path-string -> path, validate all, then build + flip
(define (profile-activate entries profile-root
                             #:interface [interface "unknown"]
                             #:specs [specs '()]
                             #:lock [lock #f])
  (when (null? entries)
    (raise-pm-error 'config 'profile-activate "nothing to activate"))
  (define triples (apply append (map (lambda (e) (apply entry-triples e))
                                     entries)))
  (check-conflicts triples)
  (make-directory* profile-root)
  (define gen (build-path profile-root
                          (gen-dir-name (next-gen-number profile-root))))
  (build-generation! triples gen)
  ;; G-10: who and why. The run id is read off the active narration
  ;; run, so the event feed of that id reconstructs this decision; the
  ;; interface names who triggered it. Outside any run both are absent
  ;; rather than invented.
  (call-with-output-file (build-path gen "provenance.rktd")
    (lambda (out)
      (write `(provenance (,(current-run-id) ,interface ,specs ,lock)) out))
    #:exists 'truncate/replace)
  (swap-link! (path->string gen)
              (path->string (build-path profile-root "profile")))
  gen)

;; path-string -> path, where the profile link points today
(define (current-generation profile-root)
  (define link (build-path profile-root "profile"))
  (unless (link-exists? link)
    (raise-pm-error 'config 'profile-remove "no active generation"))
  (resolve-path link))

;; path -> (listof string), package names owning links in a generation.
;; Store-layout targets only; anything else names nothing (dev
;; checkouts are E-19's to name, and the remove guard stays loud).
(define (generation-owner-names gen)
  (define names (make-hash))
  (define (walk dir)
    (for ([p (in-list (directory-list dir))])
      (define full (build-path dir p))
      (cond [(link-exists? full)
             (let* ([target
                     (with-handlers ([exn:fail? (lambda (e) #f)])
                       (path->string (resolve-path full)))]
                    [m (and target
                            (regexp-match #rx"/store/([^/]+)/" target))])
               (when m (hash-set! names (second m) #t)))]
            [(directory-exists? full) (walk full)]
            [else (void)])))
  (walk gen)
  (hash-map names (lambda (k v) k)))

;; path-string exact-integer -> path, repoint at generation N
(define (profile-rollback profile-root n)
  (define gen (build-path profile-root (gen-dir-name n)))
  ;; D-036: a rollback is the same consequential move as an activate,
  ;; so it is narrated the same way, and the generation it repoints at is
  ;; named in the event rather than only in the message.
  (with-op 'rollback (gen-dir-name n)
           "the profile is repointed at an earlier generation"
           #:how (path->string (build-path profile-root "profile"))
           (lambda ()
             (unless (directory-exists? gen)
               (skip 'rollback (path->string gen)
                     "the named generation is not on disk")
               (raise-pm-error 'config 'profile-rollback "unknown generation"
                               #:fields `(("generation" . ,(gen-dir-name n)))))
             (step 'rollback "swap"
                   "the profile link flips back to the earlier generation")
             (swap-link! (path->string gen)
                         (path->string (build-path profile-root "profile")))
             gen)))

;; path-string string (listof entry) -> path, new generation minus one.
;; The package must be active now and gone from the survivors; store
;; dirs are never touched (D-024). Emptying the profile deletes the
;; link and returns the profile root.
(define (profile-remove profile-root name entries)
  (when (member name (map first entries))
    (raise-pm-error
      'config
      'profile-remove
      "package still present"
      #:fields `(("package" . ,name))
    )
  )
  (unless (member name (generation-owner-names (current-generation profile-root)))
    (raise-pm-error
      'config
      'profile-remove
      "package not active"
      #:fields `(("package" . ,name))
    )
  )
  ;; D-036: removing the last package DELETES the profile link rather
  ;; than swapping it, which is a different enough outcome to narrate.
  (if (null? entries)
    (begin
      (with-op 'remove (path->string profile-root)
               "the last package is gone, so the profile link is deleted"
               (lambda ()
                 (step 'remove "unlink"
                       "no generation remains, so there is nothing to point at")
                 (delete-file (build-path profile-root "profile"))
                 (if (path? profile-root)
                   profile-root
                   (string->path profile-root)))))
    (with-op 'remove (format "~a removed from ~a" name (path->string profile-root))
             "the profile is rebuilt without this package"
             #:inputs (list name)
             (lambda ()
               (step 'remove "rebuild"
                     "a new generation is built beside the old one; store dirs are untouched")
               (profile-activate entries profile-root))))
)

;; path-string -> path, the holds file (absent reads as none held)
(define (holds-file profile-root)
  (build-path profile-root "holds.rktd"))

;; string string -> void, pins name real non-empty identities
(define (check-hold-identity name slot)
  (when (or (string=? name "") (string=? slot ""))
    (raise-pm-error 'config 'profile-hold "bad hold identity"
                    #:fields `(("name" . ,name) ("slot" . ,slot)))))

;; path-string -> (listof list), (name slot) pairs; torn reads refuse
(define (read-holds profile-root)
  (define f (holds-file profile-root))
  (if (not (file-exists? f))
      '()
      (let ([datum (read-holds-file f)])
        (if (holds-datum? datum)
            datum
            (raise-holds-bad f)))))

;; path -> jsexpr, one file read; failures become kind 'config
(define (read-holds-file f)
  (with-handlers ([exn:fail? (lambda (e) (raise-holds-bad f))])
    (call-with-input-file f read)))

;; path -> never returns, kind 'config naming the file
(define (raise-holds-bad f)
  (raise-pm-error 'config 'profile-hold "bad holds file"
                  #:fields `(("file" . ,(path->string f)))))

;; any -> boolean, list of two-string lists
(define (holds-datum? datum)
  (and (list? datum)
       (andmap holds-pair? datum)))

;; any -> boolean, one two-string list
(define (holds-pair? h)
  (and (list? h)
       (= 2 (length h))
       (string? (first h))
       (string? (second h))))

;; path-string (listof list) -> void
(define (write-holds! profile-root holds)
  (make-directory* profile-root)
  (call-with-output-file (holds-file profile-root)
    (lambda (out) (write holds out))
    #:exists 'truncate/replace))

;; path-string string string -> void, pin a slot (idempotent)
(define (profile-hold profile-root name slot)
  (check-hold-identity name slot)
  (define holds (read-holds profile-root))
  (unless (member (list name slot) holds)
    (write-holds! profile-root (append holds (list (list name slot))))))

;; path-string string string -> void, release a pin (idempotent)
(define (profile-unhold profile-root name slot)
  (check-hold-identity name slot)
  (define holds (read-holds profile-root))
  (define kept (filter (lambda (h) (not (equal? h (list name slot))))
                       holds))
  (unless (= (length kept) (length holds))
    (write-holds! profile-root kept)))

;; path-string string string -> boolean, is the slot pinned
(define (profile-held? profile-root name slot)
  (if (member (list name slot) (read-holds profile-root)) #t #f))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/path
           racket/string
           json
           "../core/errors.rkt")

  ;; All fixtures are synthetic (T-10) under one temp root: two fake
  ;; package trees plus a profile dir. Nothing touches the real home.
  (define test-root (build-path (find-system-path 'temp-dir)
                                "pm-activate-test"))
  (when (directory-exists? test-root)
    (delete-directory/files test-root))
  (define (pkgfile pkg . rels)
    (define p (apply build-path test-root pkg rels))
    (make-directory* (or (path-only p) test-root))
    (call-with-output-file p (lambda (out) (display "x" out))))
  (pkgfile "a" "bin" "prog")
  (pkgfile "a" "lib" "liba.a")
  (pkgfile "b" "bin" "other")
  (pkgfile "b" "share" "doc.txt")
  (pkgfile "c" "bin" "prog")
  (define prof (build-path test-root "profile"))
  (define (entry pkg)
    (list pkg
          (build-path test-root pkg)
          (map path->string
               (map (lambda (r) (apply build-path r))
                    (if (equal? pkg "a")
                        '(("bin" "prog") ("lib" "liba.a"))
                        (if (equal? pkg "b")
                            '(("bin" "other") ("share" "doc.txt"))
                            '(("bin" "prog"))))))))

  ;; Activate one package: generation 001 with resolving links, the
  ;; profile link flipped to it.
  (define gen1 (profile-activate (list (entry "a")) prof))
  (check-true (link-exists? (build-path gen1 "bin" "prog")))
  (check-equal? (path->string (resolve-path (build-path gen1 "bin" "prog")))
                (path->string (build-path test-root "a" "bin" "prog")))
  (check-equal? (path->string (resolve-path (build-path prof "profile")))
                (path->string gen1))
  ;; G-04: the generation records the ledger it was built from.
  (define ledger1
    (call-with-input-file (build-path gen1 "ledger.rktd") read))
  (check-equal? (car ledger1) 'ledger)
  (define prog-triple
    (for/first ([t (in-list (cdr ledger1))]
                #:when (and (list? t) (= 3 (length t))
                            (equal? (third t) "bin/prog")))
      t))
  (check-true (and prog-triple (equal? (first prog-triple) "a")))

  ;; A second generation keeps the first and moves the profile link.
  (define gen2 (profile-activate (list (entry "a") (entry "b")) prof))
  (check-equal? (length (profile-generations prof)) 2)
  (check-equal? (path->string (resolve-path (build-path prof "profile")))
                (path->string gen2))

  ;; G-10: provenance. Activate inside a run with an interface and
  ;; specs; the generation records the run id, and the feed of that id
  ;; holds the activate decision, so the two reconstruct each other. A
  ;; separate profile dir, so this scenario's generations never change
  ;; the counts the rollback and remove scenarios below assert.
  (define prof10 (build-path test-root "profile-g10"))
  (define feed-dir (build-path test-root "events-g10"))
  (make-directory* feed-dir)
  (define prov-gen
    (parameterize ([verbose-screen? #f])
      (define id (begin-run! #:who 'test #:events-dir feed-dir))
      (define g (profile-activate (list (entry "a")) (path->string prof10)
                                  #:interface "test-cli"
                                  #:specs '("specs/pkg-a.rktd")))
      (end-run! "done")
      (list id g)))
  (define prov-id (first prov-gen))
  (define prov-gens (profile-generations (path->string prof10)))
  (define prov-entry
    (for/first ([g (in-list prov-gens)]
                #:when (equal? (path->string (first g))
                               (path->string (second prov-gen))))
      g))
  (check-true (and prov-entry (list? (second prov-entry))))
  (check-equal? (first (second prov-entry)) prov-id)
  (check-equal? (second (second prov-entry)) "test-cli")
  (check-equal? (third (second prov-entry)) '("specs/pkg-a.rktd"))
  (define feed-text
    (for/fold ([acc ""])
              ([f (in-list (directory-list feed-dir))]
               #:when (regexp-match? #rx"\\.jsonl$" (path->string f)))
      (string-append acc (file->string (build-path feed-dir f)))))
  (check-true (regexp-match? #rx"START" feed-text))
  (check-true (regexp-match? (regexp-quote prov-id) feed-text))
  (check-equal? (path->string (resolve-path (build-path gen2 "bin" "other")))
                (path->string (build-path test-root "b" "bin" "other")))

  ;; Two packages claiming one path fail closed with kind 'activate:
  ;; names the file, both sides, and changes nothing.
  (define before (resolve-path (build-path prof "profile")))
  (define conflict-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (profile-activate (list (entry "a") (entry "c")) prof)
      'no-error))
  (check-pred activate-error? conflict-err)
  (check-regexp-match #rx"file conflict, nothing changed"
                      (exn-message conflict-err))
  (check-regexp-match #rx"owned-by: a" (exn-message conflict-err))
  (check-regexp-match #rx"claimed-by: c" (exn-message conflict-err))
  (check-equal? (length (profile-generations prof)) 2)
  (check-equal? (resolve-path (build-path prof "profile")) before)

  ;; Empty activation, escaping rels and missing targets refuse.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-activate '() prof)
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-activate (list (list "a" (build-path test-root "a")
                                              '("../x")))
                                  prof)
                'no-error))
  (check-pred activate-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-activate (list (list "a" (build-path test-root "a")
                                              '("bin" "gone")))
                                  prof)
                'no-error))

  ;; E-15: remove builds a generation minus the package and frees no
  ;; disk. Owner naming reads store-layout targets, so these fixtures
  ;; live under a synthetic store (E-19 extends naming to dev trees).
  (define sroot (build-path test-root "store15"))
  (define (spkgfile pkg rel)
    (define p (build-path sroot "store" pkg "default" "1.0-x" rel))
    (make-directory* (or (path-only p) sroot))
    (call-with-output-file p (lambda (out) (display "x" out))))
  (spkgfile "sa" "bin/prog")
  (spkgfile "sb" "bin/other")
  (define (sentry pkg rel)
    (list pkg (build-path sroot "store" pkg "default" "1.0-x") (list rel)))
  (define prof15 (build-path test-root "profile15"))
  (define g15
    (profile-activate (list (sentry "sa" "bin/prog")
                            (sentry "sb" "bin/other"))
                      prof15))
  (define g15b (profile-remove prof15 "sb" (list (sentry "sa" "bin/prog"))))
  (check-false (link-exists? (build-path g15b "bin" "other")))
  (check-true (link-exists? (build-path g15b "bin" "prog")))
  (check-true (file-exists? (build-path sroot "store" "sb" "default"
                                         "1.0-x" "bin" "other")))
  (check-equal? (path->string (resolve-path (build-path prof15 "profile")))
                (path->string g15b))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-remove prof15 "zzz" (list (sentry "sa" "bin/prog")))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-remove prof15 "sa" (list (sentry "sa" "bin/prog")
                                                  (sentry "sb" "bin/other")))
                'no-error))
  ;; Removing the last package deletes the link; the store is intact.
  (check-equal? (profile-remove prof15 "sa" '()) prof15)
  (check-false (link-exists? (build-path prof15 "profile")))
  (check-true (file-exists? (build-path sroot "store" "sa" "default"
                                         "1.0-x" "bin" "prog")))

  ;; Rollback repoints at a numbered generation; unknown N refuses.
  ;; Generations stay on disk: the list itself is the rollback state.
  (profile-rollback prof 1)
  (check-equal? (path->string (resolve-path (build-path prof "profile")))
                (path->string gen1))
  (check-equal? (length (profile-generations prof)) 2)
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-rollback prof 9)
                'no-error))

  ;; Hold pins a slot idempotently; unhold releases it the same way.
  (check-false (profile-held? prof "a" "default"))
  (profile-hold prof "a" "default")
  (check-true (profile-held? prof "a" "default"))
  (profile-hold prof "a" "default")
  (check-true (profile-held? prof "a" "default"))
  (profile-unhold prof "a" "default")
  (check-false (profile-held? prof "a" "default"))
  (profile-unhold prof "a" "default")
  (check-false (profile-held? prof "a" "default"))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-hold prof "" "default")
                'no-error))
  (delete-directory/files test-root))
