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
         "../install/activate.rkt"
         "manifest.rkt"
         "../git/vault.rkt"
         "../errors/error-type.rkt"
         "../machine/file-lock.rkt"
         "../spec/plan.rkt"
         "../entry/version.rkt"
         "../narration/narration.rkt")

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
  [verify-source! (-> path-string? string? string? string? void?)]
  ;; profile locks -> status rows, G-11 answers what is installed
  [query-status (-> path-string? (listof lock-entry?)
                    (listof (list/c string? string? string? boolean?
                                    (listof string?))))]
  ;; profile -> holds, G-11 answers what is held
  [query-held (-> path-string? (listof (list/c string? string?)))]))

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
;; Status (G-11). Installed comes from the generation ledger, held from
;; the holds file, outdated from the vault via update-all. Each answers
;; which source it consulted, so "what is installed" is never a guess.

;; path -> (listof list) or #f, ledger triples of one generation
(define (ledger-triples gen)
  (with-handlers ([(lambda (e) #t) (lambda (e) #f)])
    (define datum (call-with-input-file (build-path gen "ledger.rktd") read))
    (and (pair? datum)
         (eq? (car datum) 'ledger)
         (for/list ([t (in-list (cdr datum))]
                    #:when (and (list? t) (= 3 (length t))))
           t))))

;; path-string (listof lock-entry) -> status rows, one per installed
;; package: (name version slot held? rels). The ledger is authoritative
;; for what is installed; the lock supplies version and slot.
(define (query-status profile-root locks)
  (with-op 'query
           (if (path? profile-root) (path->string profile-root)
               (format "~a" profile-root))
           "the user asked what is installed"
           #:how "the current generation's ledger, slots from the lock"
           #:inputs (list (if (path? profile-root) (path->string profile-root)
                              (format "~a" profile-root)))
           (lambda ()
             (step 'query "ledger"
                   "the ledger is the record the generation was built from")
             (define gen (current-generation profile-root))
             (define triples
               (or (ledger-triples gen)
                   (raise-pm-error 'config 'query-status
                                   "generation predates ledgers"
                                   #:fields `(("generation" . ,(path->string gen)))
                                   #:hint "re-activate to write a ledger")))
             (define by-name
               (for/fold ([h (hash)])
                         ([t (in-list triples)])
                 (hash-set h (first t)
                           (cons (third t) (hash-ref h (first t) '())))))
             (step 'query "holds"
                   "a held slot stays installed on purpose, not by accident")
             (for/list ([name (in-list (sort (hash-keys by-name) string<?))])
               (define lock-hit
                 (for/or ([e (in-list locks)])
                   (and (equal? (symbol->string (lock-entry-name e)) name)
                        e)))
               (define slot
                 (if lock-hit (symbol->string (lock-entry-slot lock-hit))
                     "unknown"))
               (list name
                     (if lock-hit (version->string (lock-entry-version lock-hit))
                         "unknown")
                     slot
                     (and (not (equal? slot "unknown"))
                          (profile-held? profile-root name slot)
                          #t)
                     (reverse (hash-ref by-name name)))))))

;; path-string -> holds, (name slot) pairs as written by profile-hold
(define (query-held profile-root)
  (with-op 'query
           (if (path? profile-root) (path->string profile-root)
               (format "~a" profile-root))
           "the user asked what is held"
           #:how "the profile holds file, absent reads as none held"
           (lambda ()
             (define holds (read-holds profile-root))
             (step 'query "holds"
                   (format "~a hold(s) on record" (length holds)))
             holds)))

;; ---------------------------------------------------------------------------
