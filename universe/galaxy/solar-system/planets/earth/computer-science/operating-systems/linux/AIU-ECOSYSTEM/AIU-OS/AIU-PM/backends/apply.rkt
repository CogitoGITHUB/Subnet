#lang racket/base
;; apply.rkt -- the journaled plan interpreter (ENGINE.org
;; backends/apply.rkt, E-11).
;;
;; No special cases: every action in the plan (fetch through
;; set-current, in lowering order) runs through the given performer,
;; bracketed by journal start/end records under the plan's input
;; hash. A step whose recorded end hash still matches is skipped, so
;; a killed run resumes exactly where it stopped; anything else
;; re-runs. #:cancel raises kind 'cancelled between steps, never
;; mid-step. One writer lock (E-12c): #:writer (id note) takes
;; core/vault-lock.rkt's try-only lock on the state dir first, failing
;; fast naming the holder; try-only never blocks, so it is safe even
;; in-process (P-04). Readers (journal queries) never lock; jobs keep
;; queue-time concerns. #:manifest + #:manifest-entry upsert the
;; declaration on success only: apply is the only manifest writer
;; (E-14; jobs.rkt:595 retires in Phase C, vault's use is fixtures).
;;
;; D-041: every phase here that can block says so FIRST through
;; core/verbose.rkt's wait-for -- the specs scan, the lock read, resolve
;; and derive, the staging clear, the writer lock, each journalled step's
;; read/start/perform/end, each action, the manifest read and write, and
;; the collection. The reasons are per ACTION KIND, so a park names what
;; was unfinished ("readers must not see the new version until the flip
;; is atomic") and not just an index. There is no off-switch.

(require racket/contract/base
         racket/file
         racket/list
         racket/path
         racket/string
         "journal.rkt"
         "local.rkt"
         "manifest.rkt"
         "query.rkt"
         "vault.rkt"
         "../core/errors.rkt"
         "../core/lock.rkt"
         "../core/plan.rkt"
         "../core/scope.rkt"
         "../core/spec.rkt"
         "../core/spec-read.rkt"
         "../core/vault-lock.rkt"
         "../core/verbose.rkt"
         "../core/version.rkt")

(provide
 (contract-out
  ;; plan string performer -> void, journaled run, resume by hash.
  ;; #:writer (id note) takes the try-only store writer lock first.
  [apply-plan (->* (plan? string? (-> action? void?)
                          #:state path-string?
                          #:package string?
                          #:slot string?)
                   (#:cancel (or/c evt? #f)
                    #:writer (or/c #f (list/c string? string?))
                    #:manifest (or/c path-string? #f)
                    #:manifest-entry (or/c manifest-entry? #f))
                   void?)]
  ;; -> path, the state root pm commands use when none is given
  [default-state-dir (-> path?)]
  ;; specs-dir vault -> ordered specs, read, conflicts, source preflight
  [scan-specs (->* (path-string? path-string?)
                   (#:preflight boolean?)
                   (listof spec?))]
  ;; specs-dir -> (name plan-text), the whole plan rendered, no effects
  [pm-apply-dry (->* (path-string?)
                     (#:lock (or/c path-string? #f))
                     (listof (list/c string? string?)))]
  ;; specs-dir -> results, derive on the spot and apply for real
  [pm-apply (->* (path-string?)
                 (#:state path-string?
                  #:manifest (or/c path-string? #f)
                  #:prefix (or/c path-string? #f)
                  #:vault (or/c path-string? #f)
                  #:lock (or/c path-string? #f)
                  #:dry-run boolean?
                  #:cancel (or/c evt? #f))
                 (listof (list/c string? symbol? list?)))]))

;; action -> string, stable kind label for journal step names. Index
;; plus kind names the step; plans lower deterministically, so the
;; name is stable across the runs that resume each other.
(define (action-kind a)
  (cond [(fetch-action? a) "fetch"]
        [(extract-action? a) "extract"]
        [(run-step-action? a) "run-step"]
        [(install-file-action? a) "install-file"]
        [(write-file-action? a) "write-file"]
        [(symlink-action? a) "symlink"]
        [(remove-path-action? a) "remove-path"]
        [(export-action? a) "export"]
        [(check-action? a) "check"]
        [(mark-incomplete-action? a) "mark-incomplete"]
        [(clear-incomplete-action? a) "clear-incomplete"]
        [(set-current-action? a) "set-current"]
        [else (raise-pm-error 'internal 'apply-plan "not an action"
                              #:fields `(("value" . ,(format "~s" a))))]))

;; action -> string, why THIS kind must finish before the next action
;; starts. One line per kind the lowerer emits, so a WAIT record names
;; the reason and not just an index: a park on the current flip says
;; "readers must not see the new version" instead of "step-5".
(define (action-why a)
  (cond [(export-action? a)
         "nothing can be built until the pin is exported into staging"]
        [(extract-action? a)
         "nothing can be built from a commit that is not on disk yet"]
        [(fetch-action? a)
         "the pin must be in the mirror before anything can read it"]
        [(mark-incomplete-action? a)
         "a crash after this point must leave the store marked incomplete"]
        [(run-step-action? a)
         "the files this step makes do not exist until it exits zero"]
        [(install-file-action? a)
         "the file is not under the prefix until the copy lands"]
        [(write-file-action? a)
         "the file is not under the prefix until the atomic write lands"]
        [(symlink-action? a)
         "no reader can resolve the link until it exists"]
        [(remove-path-action? a)
         "a later action must not see a path this one removes"]
        [(check-action? a)
         "the package is not proven good until this check exits zero"]
        [(clear-incomplete-action? a)
         "the store must not read complete while this marker still stands"]
        [(set-current-action? a)
         "readers must not see the new version until the flip is atomic"]
        [else "the plan requires this action to finish before the next one starts"]))

;; plan string performer -> void, one journaled pass over the plan,
;; under the writer lock when #:writer names one
(define (apply-plan p input-hash performer
                    #:state state
                    #:package package
                    #:slot slot
                    #:cancel [cancel #f]
                    #:writer [writer #f]
                    #:manifest [manifest #f]
                    #:manifest-entry [entry #f])
  (define (run)
    (define actions (plan-actions p))
    ;; D-036: the whole apply is one narrated operation, and EVERY
    ;; action is narrated -- including the ones the journal says are
    ;; already done, which is the skip reason a resumed run must show.
    (with-op 'apply
             (string-append (number->string (length actions)) " action(s)")
             "the plan's actions must all reach their recorded end state"
             #:how (format "input hash ~a" input-hash)
             #:inputs (map action-kind actions)
             (lambda ()
               (for ([a (in-list actions)] [i (in-range (length actions))])
                 (define step-id (format "step-~a-~a" i (action-kind a)))
                 (when (and cancel (sync/timeout 0 cancel))
                   (raise-pm-error 'cancelled 'apply-plan "cancelled between steps"
                                   #:fields `(("step" . ,step-id))))
                 ;; D-041: each of the four phases around one action says
                 ;; itself BEFORE it blocks. The journal read decides
                 ;; skip-vs-run, the start record must be durable before the
                 ;; performer runs, the performer is the only phase that
                 ;; spawns, and the end record is what the NEXT run reads.
                 ;; A park in any of them now names itself.
                 (if (wait-for 'apply step-id
                               "the journal must say whether this step ran under this hash"
                               #:how (format "read journal ~a/~a" package slot)
                               (lambda ()
                                 (journal-step-done? state package slot
                                                    step-id input-hash)))
                     (skip 'apply
                           (format "step-~a-~a" i (action-kind a))
                           (string-append
                            "the journal already records this step as done"
                            " under input hash " input-hash))
                     (begin
                       (step 'apply
                             (format "step-~a-~a" i (action-kind a))
                             "the journal has no end record for this input hash"
                             #:how (format "input hash ~a" input-hash))
                       (wait-for 'apply step-id
                                 "the start record must be on disk before the step runs"
                                 #:how (format "journal start ~a" step-id)
                                 (lambda ()
                                   (journal-record-start! state package slot
                                                          step-id input-hash)))
                       (wait-for 'apply step-id
                                 "this step cannot be journalled done until the performer finishes"
                                 #:how (format "perform ~a" (action-kind a))
                                 (lambda () (performer a)))
                       (wait-for 'apply step-id
                                 "the end record is the only proof the next run reads"
                                 #:how (format "journal end ~a" step-id)
                                 (lambda ()
                                   (journal-record-end! state package slot
                                                        step-id input-hash))))))
               (when (and manifest entry)
                 (step 'apply
                       "manifest"
                       "the plan declared a manifest entry to write")
                 (define existing
                   (wait-for 'apply "manifest-read"
                             "the upsert needs the entries already on disk"
                             #:how (format "read ~a" manifest)
                             (lambda () (manifest-read manifest))))
                 (wait-for 'apply "manifest-write"
                           "the declared entry is not recorded until the upsert lands"
                           #:how (format "write ~a" manifest)
                           (lambda ()
                             (manifest-write
                              manifest
                              (manifest-upsert existing entry))))))))
  (if writer
      (wait-for 'apply "writer-lock"
                "only one writer may hold the store, so the lock is taken before any step"
                #:how (format "lock ~a as ~a" state (first writer))
                (lambda ()
                  (call-with-vault-lock state (first writer) (second writer) run)))
      (run))
  ;; D-041 GC. Every spawned child leaves a custodian and two or three
  ;; threads behind, and they are only reclaimed by a collection. This is
  ;; narrated because a park inside a collection is indistinguishable from
  ;; a park in a spawn, and the e2e fd census reads what is left over.
  (wait-for 'apply "gc"
            "the custodians and threads each spawned child left behind are reclaimed here"
            #:how "collect-garbage after the pass"
            (lambda () (collect-garbage) (void))))

;; ---------------------------------------------------------------------------
;; Derive on the spot (D-040): specs dir plus lock through scan,
;; resolve, lower and apply-plan. No plan file is stored or read, so no
;; stale plan can ever be applied.

;; -> path, the state root pm commands use when none is given
(define (default-state-dir)
  (build-path (roots-data (scope-roots 'user)) "aiu-pm"))

;; path-string -> (listof path), sorted .rktd files, no network
(define (spec-files dir)
  (sort (for/list ([p (in-list (directory-list dir))]
                   #:when (and (file-exists? (build-path dir p))
                               (string-suffix? (path->string p) ".rktd")))
          (build-path dir p))
        path<?))

;; path-string path-string -> (listof spec). Scan reads every spec,
;; refuses collisions with both names, and preflights each source
;; against the vault (pin still resolves there). Read-only except the
;; vault presence it ensures, which fetch would do anyway; dry runs
;; pass #:preflight #f and change nothing at all.
(define (scan-specs specs-dir vault-root #:preflight [preflight #t])
  (with-op 'scan (if (path? specs-dir) (path->string specs-dir)
                     (format "~a" specs-dir))
           "every declaration is valid and every source resolves"
           #:inputs (list (if (path? specs-dir) (path->string specs-dir)
                              (format "~a" specs-dir)))
           (lambda ()
             ;; D-041: the dir listing and every spec read are filesystem
             ;; waits, and the preflight below spawns git per package. Both
             ;; say so before they block.
             (define specs
               (wait-for 'scan "scan-specs"
                         "no package can be derived until every spec in the dir is read"
                         #:how "read each spec in the specs dir"
                         (lambda ()
                           (for/list ([f (in-list (spec-files specs-dir))])
                             (define s (read-spec-file f))
                             (step 'scan
                                   (string-append
                                    (symbol->string (spec-name s)) " "
                                    (version->string (spec-version s)))
                                   "the spec parsed and passed every field check"
                                   #:how (path->string f))
                             s))))
             (step 'scan "conflicts"
                   "no two packages may claim one destination")
             (check-spec-conflicts specs)
             (when preflight
               (for ([s (in-list specs)])
                 (define name (symbol->string (spec-name s)))
                 (define src (spec-source s))
                 (wait-for 'scan "vault-preflight"
                           "the pin must already resolve in the vault or the export below cannot work"
                           #:how (format "verify ~a at ~a" name (source-commit src))
                           (lambda ()
                             (verify-source! vault-root name
                                             (source-url src)
                                             (source-commit src))))))
             specs)))

;; (listof spec) path-string -> void, lock pins hold for every spec
(define (check-lock specs lock-path)
  (define table
    (wait-for 'apply "lock-read"
              "a declaration can only be compared to a lockfile that has been read"
              #:how (format "read ~a" lock-path)
              (lambda ()
                (for/hash ([e (in-list (lockfile-entries
                                        (read-lockfile lock-path)))])
                  (values (symbol->string (lock-entry-name e)) e)))))
  (for ([s (in-list specs)])
    (define name (symbol->string (spec-name s)))
    (define hit (hash-ref table name #f))
    (when hit
      (define want-ver (version->string (lock-entry-version hit)))
      (define want-pin (lock-entry-commit hit))
      (define got-ver (version->string (spec-version s)))
      (define got-pin (source-commit (spec-source s)))
      (unless (and (equal? want-ver got-ver) (equal? want-pin got-pin))
        (raise-pm-error 'config 'pm-apply "declaration drifted from lock"
                        #:fields `(("package" . ,name)
                                   ("lock" . ,(string-append want-ver " " want-pin))
                                   ("spec" . ,(string-append got-ver " " got-pin)))
                        #:hint "update the lock or the spec so they agree")))))

;; (listof spec) -> (listof package-plan), resolve then derive
(define (resolve-and-derive specs)
  (wait-for 'apply "resolve-derive"
            "nothing can be applied until every package has a lowered plan in resolve order"
            #:how (format "derive ~a package(s)" (length specs))
            (lambda () (derive-plans specs '() '()))))

;; path-string -> string, scratch dir for one package. Created only
;; when missing, never cleared: the fetch action clones into an empty
;; dir and updates an existing mirror, so deleting here would break
;; both the clone decision and resume.
(define (fresh-work-dir state name)
  (define d (build-path state "work" name))
  (unless (directory-exists? d)
    (wait-for 'apply "work-dir"
              "the staging dir must exist before an action writes or clones into it"
              #:how (format "create ~a" d)
              (lambda ()
                (make-directory* d)
                (void))))
  (path->string d))

;; path-string -> (listof (name plan-text)), the whole plan rendered.
;; No vault touch, no dirs, no manifest: a dry run changes nothing.
(define (pm-apply-dry specs-dir #:lock [lock #f])
  (define specs (scan-specs specs-dir "" #:preflight #f))
  (when lock
    (check-lock specs lock))
  (define pps (resolve-and-derive specs))
  (for/list ([pp (in-list pps)])
    (list (symbol->string (package-plan-name pp))
          (plan->text (list->plan
                       (lower-package-plan
                        pp
                        "dry-run-no-url"
                        (path->string (find-system-path 'temp-dir))
                        (path->string (find-system-path 'temp-dir))
                        (path->string (find-system-path 'temp-dir))))))))

;; path-string -> results. Derive on the spot and apply for real, one
;; package at a time in resolve order, fail closed at the first
;; failure. One writer lock spans the whole run: a second apply fails
;; at once naming the holder instead of interleaving.
(define (pm-apply specs-dir
                  #:state [state #f]
                  #:manifest [manifest #f]
                  #:prefix [prefix #f]
                  #:vault [vault #f]
                  #:lock [lock #f]
                  #:dry-run [dry-run #f]
                  #:cancel [cancel #f])
  (define state-dir (if state (as-dir state) (path->string (default-state-dir))))
  (define manifest-path
    (if manifest (as-dir manifest)
        (path->string (build-path state-dir "manifest.rktd"))))
  (define prefix-dir
    (if prefix (as-dir prefix) (path->string (build-path state-dir "prefix"))))
  (define vault-git
    (if vault (as-dir vault)
        (path->string (build-path (default-state-dir) "vault" "vault.git"))))
  (wait-for 'apply "state-dir"
            "the state root must exist before a journal or a store dir can live under it"
            #:how (format "create ~a" state-dir)
            (lambda ()
              (make-directory* state-dir)
              (void)))
  (with-op 'apply (as-dir specs-dir)
           (if dry-run "the plan is shown and nothing changes"
               "every package installs in resolve order")
           (lambda ()
             (unless (or dry-run (directory-exists? vault-git))
               (step 'apply "vault-init"
                     "the vault does not exist yet, so it is created empty")
               (define vault-parent
                 (or (path-only (string->path vault-git))
                     (string->path vault-git)))
               (wait-for 'apply "vault-init"
                         "the empty vault cannot exist until git has made the bare repo"
                         #:how (format "vault-init ~a" vault-git)
                         (lambda ()
                           (make-directory* vault-parent)
                           (vault-init vault-git))))
             ;; scan-specs narrates its own dir listing, per-spec reads and
             ;; per-package vault preflight, so this only names the phase.
             (define specs (scan-specs specs-dir vault-git #:preflight (not dry-run)))
             (wait-for 'apply "prefix-dirs"
                       "each package needs its own prefix dir before a current link can land there"
                       #:how (format "create ~a/<package>" prefix-dir)
                       (lambda ()
                         (for ([s (in-list specs)])
                           (make-directory*
                            (build-path prefix-dir
                                        (symbol->string (spec-name s)))))
                         (void)))
             (when lock
               (step 'apply "lock"
                     "the declaration must agree with the lockfile")
               (check-lock specs lock))
             (define pps (resolve-and-derive specs))
             (wait-for 'apply "gc"
                       "the custodians and threads each spawned child left behind are reclaimed here"
                       #:how "collect-garbage after the run"
                       (lambda () (collect-garbage) (void)))
             (if dry-run
                 (for/list ([pp (in-list pps)])
                   (list (symbol->string (package-plan-name pp))
                         'planned
                         '()))
                 (wait-for 'apply "writer-lock"
                           "only one writer may hold the store, so the try-only lock is taken first"
                           #:how (format "lock ~a as pm-apply" state-dir)
                           (lambda ()
                             (call-with-vault-lock
                              state-dir "pm-apply" (format "apply ~a" specs-dir)
                              (lambda ()
                                (define by-name
                                  (for/hash ([s (in-list specs)])
                                    (values (symbol->string (spec-name s)) s)))
                                (for/list ([pp (in-list pps)])
                                  (wait-for
                                   'apply
                                   (format "apply-package ~a"
                                           (symbol->string
                                            (package-plan-name pp)))
                                   "one package is fully installed before the next one starts"
                                   #:how (format "package-plan slot ~a"
                                                 (symbol->string
                                                  (package-plan-slot pp)))
                                   (lambda ()
                                     (apply-one
                                      pp
                                      (hash-ref by-name
                                                (symbol->string
                                                 (package-plan-name pp)))
                                      state-dir manifest-path prefix-dir
                                      vault-git cancel)))))))))))

;; path-or-string -> string
(define (as-dir d)

;; package-plan state manifest prefix vault cancel -> result. One
;; package, fully installed, with per-action outcomes timed.
(define (apply-one pp spec state manifest prefix vault cancel)
  (define name (symbol->string (package-plan-name pp)))
  (define slot (symbol->string (package-plan-slot pp)))
  (define src (spec-source spec))
  ;; The vault already holds the pin (scan ensured it, build-lua E-12b
  ;; precedent): the plan's own fetch is filtered and the export tree
  ;; starts empty, because one dir cannot be both mirror and tree.
  ;; A completed export is never cleared: resume reuses its tree. Step
  ;; ids below are over the filtered actions, matching the journal.
  (define versioned
    (path->string (build-path state "store" (package-plan-store-dir pp))))
  (define linkto (path->string (build-path prefix name "current")))
  (define staging (fresh-work-dir state name))
  (define actions
    (wait-for 'apply "lower-plan"
              "no step id, and so no journal record, exists before the plan is lowered"
              #:how (format "lower ~a" name)
              (lambda ()
                (filter (lambda (a) (not (fetch-action? a)))
                        (lower-package-plan pp
                                            (source-url src)
                                            staging versioned linkto)))))
  (define export-id
    (let ([i (for/first ([a (in-list actions)]
                         [n (in-naturals)]
                         #:when (export-action? a))
               n)])
      (and i (format "step-~a-export" i))))
  ;; D-041: the staging clear is the one destructive thing this function
  ;; does, and it walks a whole exported tree. It says so first, and it
  ;; says WHICH package's tree it is about to remove.
  (when (or (not export-id)
            (not (journal-step-done? state name slot export-id
                                     (package-plan-input-hash pp))))
    (when (directory-exists? staging)
      (wait-for 'apply "clear-staging"
                "one dir cannot be both mirror and export tree, so a re-export needs an empty one"
                #:how (format "remove ~a" staging)
                (lambda () (delete-directory/files staging))))
    (wait-for 'apply "make-staging"
              "the export below writes into this dir and will not create it"
              #:how (format "create ~a" staging)
              (lambda ()
                (make-directory* staging)
                (void))))
  (define plan (list->plan actions))
  (define outcomes (make-hash))
  (define current-id (box #f))
  ;; The performer prefix is the versioned dir, not the prefix root:
  ;; install dests land under versioned/, so confinement must measure
  ;; against it (e12 precedent). The current link still goes under the
  ;; shared prefix root.
  (define (tracking-performer commit* vault*)
    (lambda (a)
      (define id (step-id-for actions a))
      (set-box! current-id id)
      (define t0 (current-inexact-monotonic-milliseconds))
      ;; D-041, per action: the reason is per KIND, so a park names what
      ;; was unfinished. The export, the marker, the build, the copies,
      ;; the check, the clear and the current flip each say why they are
      ;; still running before they block.
      (wait-for 'apply (action-kind a)
                (action-why a)
                #:how (format "~a into ~a" id versioned)
                (lambda () (perform-action! a versioned commit* vault*)))
      (define ms (inexact->exact
                  (round (- (current-inexact-monotonic-milliseconds) t0))))
      (hash-set! outcomes id (list 'applied ms))))
  (define failed-id (box #f))
  (define failed-message (box ""))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (unbox current-id)
                       (set-box! failed-id (unbox current-id))
                       (set-box! failed-message (exn-message e)))
                     (raise e))])
    (wait-for 'apply "apply-plan"
              "the package is not installed until every journalled step has reached its end state"
              #:how (format "~a action(s) for ~a" (length actions) name)
              (lambda ()
                (apply-plan plan
                            (package-plan-input-hash pp)
                            (tracking-performer (source-commit src)
                                                vault)
                            #:state state
                            #:package name
                            #:slot slot
                            #:cancel cancel
                            #:manifest manifest
                            #:manifest-entry
                            (manifest-entry name
                                            (source-url src)
                                            (vault-namespace name)
                                            (current-seconds)
                                            #f
                                            '()
                                            #f)))))
  (define input-hash (package-plan-input-hash pp))
  (define rows
    (for/list ([a (in-list actions)] [i (in-naturals)])
      (define id (format "step-~a-~a" i (action-kind a)))
      (cond [(equal? id (unbox failed-id))
             (list id 'failed 0 (unbox failed-message))]
            [(hash-ref outcomes id #f)
             => (lambda (r) (list id 'applied (second r) "performed for real"))]
            [else (list id 'skipped 0
                        (format "input hash ~a matches the journal" input-hash))])))
  (list name
        (if (for/and ([r (in-list rows)]) (eq? (second r) 'skipped))
            'skipped
            'applied)
        rows))

;; (listof action) action -> string, the journal step id for one action
(define (step-id-for actions a)
  (define-values (found _)
    (for/fold ([hit #f] [i 0]) ([x (in-list actions)])
      (if hit
          (values hit (add1 i))
          (if (equal? x a)
              (values (format "step-~a-~a" i (action-kind a)) (add1 i))
              (values #f (add1 i))))))
  (or found
      (raise-pm-error 'internal 'pm-apply "action not in its own plan"
                      #:fields `(("action" . ,(format "~s" a))))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/list
           racket/path
           racket/string
           "fake.rkt"
           "local.rkt"
           "manifest.rkt"
           "git.rkt"
           "run.rkt"
           "vault.rkt"
           "../core/git-url.rkt"
           "../core/errors.rkt"
           "../core/plan.rkt")

  ;; All fixtures are synthetic (T-10): plans over fake actions, one
  ;; temp state dir, package names isolating the scenarios. The fake
  ;; performer spawns nothing and touches no prefix.
  (define state-root (build-path (find-system-path 'temp-dir)
                                 "pm-apply-test"))
  (when (directory-exists? state-root)
    (delete-directory/files state-root))
  (make-directory* state-root)
  (define state (path->string state-root))

  ;; A green run performs every action in order and journals each end.
  (define green-plan
    (list->plan
     (list (mark-incomplete-action "/tmp/pm-apply-x/ver")
           (run-step-action "make" '("make" "all") "/tmp/pm-apply-x")
           (write-file-action "/tmp/pm-apply-x/out.txt" "x")
           (clear-incomplete-action "/tmp/pm-apply-x/ver"))))
  (define green-box (box '()))
  (parameterize ([current-fake-log green-box])
    (apply-plan green-plan "h1" fake-perform!
                #:state state #:package "pkg-green" #:slot "default"))
  (check-equal? (length (unbox green-box)) 4)
  (check-true (mark-incomplete-action? (last (unbox green-box))))
  (check-equal? (length (journal-completions state "pkg-green" "default"))
                4)

  ;; A failing build stops the run: earlier steps are done, the failed
  ;; step holds a start without an end, nothing after it ran.
  (define boom-performer
    (lambda (a)
      (if (run-step-action? a)
          (raise-pm-error 'build 'boom "simulated failing build"
                          #:fields `(("step" . "run-step")))
          (fake-perform! a))))
  (define fail-plan
    (list->plan
     (list (mark-incomplete-action "/tmp/pm-apply-x/ver")
           (write-file-action "/tmp/pm-apply-x/a.txt" "a")
           (run-step-action "boom" '("boom") "/tmp/pm-apply-x")
           (write-file-action "/tmp/pm-apply-x/b.txt" "b"))))
  (define run1-box (box '()))
  (define boom-err
    (parameterize ([current-fake-log run1-box])
      (with-handlers ([exn:fail:pm? (lambda (e) e)])
        (apply-plan fail-plan "h9" boom-performer
                    #:state state #:package "pkg-fail" #:slot "default")
        'no-error)))
  (check-pred build-error? boom-err)
  (check-equal? (length (unbox run1-box)) 2)
  (check-true (journal-step-done? state "pkg-fail" "default"
                                  "step-0-mark-incomplete" "h9"))
  (check-true (journal-step-done? state "pkg-fail" "default"
                                  "step-1-write-file" "h9"))
  (check-false (journal-step-done? state "pkg-fail" "default"
                                   "step-2-run-step" "h9"))

  ;; Resume re-runs only from the failed step: completed steps skip.
  (define run2-box (box '()))
  (parameterize ([current-fake-log run2-box])
    (apply-plan fail-plan "h9" fake-perform!
                #:state state #:package "pkg-fail" #:slot "default"))
  (check-equal? (length (unbox run2-box)) 2)
  (check-true (run-step-action? (last (unbox run2-box))))
  (check-true (journal-step-done? state "pkg-fail" "default"
                                  "step-2-run-step" "h9"))

  ;; G-07: applying the same plan twice is a no-op. Every step is done
  ;; under h9, so the performer runs zero times and each action SKIPs.
  (define run2b-box (box '()))
  (parameterize ([current-fake-log run2b-box])
    (apply-plan fail-plan "h9" fake-perform!
                #:state state #:package "pkg-fail" #:slot "default"))
  (check-equal? (unbox run2b-box) '())

  ;; A changed input hash reruns everything, skipping nothing.
  (define run3-box (box '()))
  (parameterize ([current-fake-log run3-box])
    (apply-plan fail-plan "hOTHER" fake-perform!
                #:state state #:package "pkg-fail" #:slot "default"))
  (check-equal? (length (unbox run3-box)) 4)

  ;; G-08: the feed of an interrupted run shows the law. Inside one
  ;; verbose run, the failing apply emits FAIL and the resumed apply
  ;; emits SKIPs naming the hash, so a reader of the feed knows the run
  ;; resumed rather than restarted.
  (define feed-dir (build-path state "events-g08"))
  (make-directory* feed-dir)
  (define feed-text
    (parameterize ([verbose-screen? #f])
      (begin-run! #:who 'test #:events-dir feed-dir)
      (with-handlers ([exn:fail:pm? void?])
        (apply-plan fail-plan "hG08" boom-performer
                    #:state state #:package "pkg-g08" #:slot "default"))
      (apply-plan fail-plan "hG08" fake-perform!
                  #:state state #:package "pkg-g08" #:slot "default")
      (end-run! "done")
      (for/fold ([acc ""])
                ([f (in-list (directory-list feed-dir))]
                 #:when (regexp-match? #rx"\\.jsonl$" (path->string f)))
        (string-append acc (file->string (build-path feed-dir f))))))
  (check-true (regexp-match? #rx"FAIL" feed-text))
  (check-true (regexp-match? #rx"SKIP" feed-text))
  (check-true (regexp-match? #rx"hG08" feed-text))

  ;; Cancel stops between steps: nothing performed, nothing journaled.
  (define cancel-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (parameterize ([current-fake-log (box '())])
        (apply-plan green-plan "h1" fake-perform!
                    #:state state #:package "pkg-cancel" #:slot "default"
                    #:cancel always-evt))
      'no-error))
  (check-pred cancelled-error? cancel-err)
  (check-equal? (journal-completions state "pkg-cancel" "default") '())

  ;; Cancel keeps the marker: the performer posts right after the
  ;; real mark step, so the peek-evt fires from the next step on. The
  ;; interrupted dir stays marked and the step after it never ran.
  ;; Deterministic: everything happens on one thread, no timers, no
  ;; sleeps, post never blocks and peek never waits.
  (define cancel-sem (make-semaphore 0))
  (define cancel-box (box '()))
  (define cancel-performer
    (lambda (a)
      (cond [(mark-incomplete-action? a)
             (local-perform! (list->plan (list a)))
             (fake-perform! a)
             (semaphore-post cancel-sem)]
            [else (fake-perform! a)])))
  (define cancel-ver (build-path state-root "cancel-ver"))
  (define cancel-plan
    (list->plan
     (list (mark-incomplete-action (path->string cancel-ver))
           (write-file-action (path->string (build-path cancel-ver "w.txt")) "w")
           (clear-incomplete-action (path->string cancel-ver)))))
  (define cancel2-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (parameterize ([current-fake-log cancel-box])
        (apply-plan cancel-plan "hc" cancel-performer
                    #:state state #:package "pkg-cancel2" #:slot "default"
                    #:cancel (semaphore-peek-evt cancel-sem)))
      'no-error))
  (check-pred cancelled-error? cancel2-err)
  (check-true (file-exists? (build-path cancel-ver ".pm-incomplete")))
  (check-true (journal-step-done? state "pkg-cancel2" "default"
                                  "step-0-mark-incomplete" "hc"))
  (check-false (journal-step-done? state "pkg-cancel2" "default"
                                   "step-1-write-file" "hc"))

  ;; An empty plan is void, never an error.
  (check-not-exn
   (lambda ()
     (apply-plan (list->plan '()) "h" fake-perform!
                 #:state state #:package "pkg-empty" #:slot "default")))

  ;; E-12: pkg-alpha end to end on real local fixtures. A synthetic
  ;; upstream repo (one script, one one-line makefile) goes through
  ;; vault fetch and export, a real store dir, the real marker and the
  ;; real current link, all driven by apply-plan over local-perform!.
  (define e12-home (build-path state-root "home"))
  (make-directory e12-home)
  (define (e12-git dir . args)
    (define res
      (run-command (git-executable-path) args
                   #:cwd (path->string dir)
                   #:kind 'fetch #:operation "e12-fixture"
                   #:env `(("GIT_AUTHOR_NAME" . "t")
                            ("GIT_AUTHOR_EMAIL" . "t@t")
                            ("GIT_COMMITTER_NAME" . "t")
                            ("GIT_COMMITTER_EMAIL" . "t@t")
                            ("HOME" . ,(path->string e12-home))
                            ("GIT_CONFIG_NOSYSTEM" . "1"))))
    (unless (zero? (run-result-exit res))
      (error 'e12-fixture "git failed: ~a" args))
    res)
  (define e12-up (build-path state-root "upstream"))
  (make-directory e12-up)
  (e12-git e12-up "init" "-b" "main" ".")
  (call-with-output-file (build-path e12-up "build.sh")
    (lambda (out) (display "#!/bin/sh\nprintf alpha > built.txt\n" out)))
  (call-with-output-file (build-path e12-up "makefile")
    (lambda (out) (display "all:\n\tsh build.sh\n" out)))
  (e12-git e12-up "add" "-A")
  (e12-git e12-up "commit" "-qm" "init")
  (define e12-vault-git (build-path state-root "e12vault" "vault.git"))
  (make-directory* (build-path state-root "e12vault"))
  (define e12-mirror (build-path state-root "e12mirror.git"))
  (define e12-staging (build-path state-root "e12staging"))
  (make-directory e12-staging)
  (define e12-ver (build-path state-root "store" "pkg-alpha" "default"
                              "1.0-e12e12e12e12"))
  (define e12-cur (build-path state-root "store" "pkg-alpha" "default"
                              "current"))
  (define e12-pin
    (parameterize ([current-allow-file-urls #t])
      (vault-init e12-vault-git)
      (vault-add-result-pin
       (vault-add e12-vault-git "pkg-alpha"
                  (string-append "file://" (path->string e12-up))))))
  (define e12-actions
    (list (fetch-action (string-append "file://" (path->string e12-up))
                        e12-pin
                        (path->string e12-mirror))
          (export-action 'pkg-alpha e12-pin (path->string e12-staging))
          (mark-incomplete-action (path->string e12-ver))
          (run-step-action "make" '("make" "-f" "makefile" "all")
                           (path->string e12-staging))
          (install-file-action
           (path->string (build-path e12-staging "built.txt"))
           (path->string (build-path e12-ver "built.txt"))
           #o644)
          (check-action '("sh" "-c" "test -f built.txt")
                        (path->string e12-ver))
          (clear-incomplete-action (path->string e12-ver))
          (set-current-action (path->string e12-ver)
                              (path->string e12-cur))))
  (define (e12-perform! a)
    (local-perform! (list->plan (list a))
                    #:prefix (path->string e12-ver)
                    #:commit e12-pin
                    #:vault (path->string e12-vault-git)))
  (parameterize ([current-allow-file-urls #t])
    (apply-plan (list->plan e12-actions) "e12" e12-perform!
                #:state state #:package "pkg-alpha" #:slot "default"))
  (check-equal? (file->string (build-path e12-ver "built.txt")) "alpha")
  (check-false (file-exists? (build-path e12-ver ".pm-incomplete")))
  (check-equal? (path->string (resolve-path e12-cur))
                (path->string e12-ver))
  (check-equal? (length (journal-completions state "pkg-alpha" "default"))
                8)
  (displayln "--- e12 store tree (ls -lR) ---")
  (define e12-ls
    (run-command (find-executable-path "ls")
                 (list "-lR" (path->string (build-path state-root "store")))
                 #:cwd state
                 #:kind 'build #:operation "e12-ls"))
  (for ([line (in-list (run-result-stdout-lines e12-ls))])
    (displayln line))
  (displayln "--- e12 journal ---")
  (displayln (file->string (journal-file state "pkg-alpha" "default")))

  ;; E-12c: one writer. The outer apply holds (id outer-apply) while
  ;; its performer runs the inner apply on the same state: the inner
  ;; try fails at once naming the holder, the outer completes unharmed
  ;; and the inner journal stays empty. Same thread, try-only, no wait.
  (define lock-box (box '()))
  (define inner-err-box (box #f))
  (define (lock-outer-performer a)
    (when (and (write-file-action? a) (not (unbox inner-err-box)))
      (set-box! inner-err-box
                 (with-handlers ([exn:fail:pm? (lambda (e) e)])
                   (apply-plan (list->plan (list (write-file-action
                                                  "/tmp/pm-apply-x/i.txt"
                                                  "i")))
                               "li" fake-perform!
                               #:state state #:package "pkg-inner"
                               #:slot "default"
                               #:writer (list "inner-apply"
                                              "second writer"))
                   'no-error)))
    (fake-perform! a))
  (define lock-plan
    (list->plan
     (list (write-file-action "/tmp/pm-apply-x/o1.txt" "o")
           (write-file-action "/tmp/pm-apply-x/o2.txt" "o"))))
  (parameterize ([current-fake-log lock-box])
    (apply-plan lock-plan "lw" lock-outer-performer
                #:state state #:package "pkg-lock" #:slot "default"
                #:writer (list "outer-apply" "first writer")))
  (define inner-err (unbox inner-err-box))
  (check-pred config-error? inner-err)
  (check-regexp-match #rx"outer-apply" (exn-message inner-err))
  (check-equal? (length (unbox lock-box)) 2)
  (check-equal? (length (journal-completions state "pkg-lock" "default"))
                2)
  (check-equal? (journal-completions state "pkg-inner" "default") '())

  ;; E-14: apply writes the manifest itself, on success only. The seed
  ;; entry survives (upsert, never overwrite); a failed run changes
  ;; nothing; without manifest args the run still succeeds journaled.
  (define mfile (build-path state-root "manifest.rktd"))
  (define seed-entry
    (manifest-entry "pkg-other" "https://example.org/o.git"
                    "refs/vault/pkg-other" 1 #f '() #f))
  (manifest-write mfile (list seed-entry))
  (define synth-entry
    (manifest-entry "pkg-synth" "https://example.org/s.git"
                    "refs/vault/pkg-synth" 2 #f '() #f))
  (define mplan
    (list->plan (list (write-file-action "/tmp/pm-apply-x/m.txt" "m"))))
  (define mbox (box '()))
  (parameterize ([current-fake-log mbox])
    (apply-plan mplan "hm" fake-perform!
                #:state state #:package "pkg-synth" #:slot "default"
                #:manifest mfile #:manifest-entry synth-entry))
  (check-equal? (manifest-read mfile) (list seed-entry synth-entry))
  ;; A failing run leaves the manifest exactly as it was.
  (define mfile2 (build-path state-root "manifest2.rktd"))
  (manifest-write mfile2 (list seed-entry))
  (with-handlers ([exn:fail:pm? (lambda (e) e)])
    (apply-plan mplan "hmx"
                (lambda (a) (raise-pm-error 'build 'm14 "boom"))
                #:state state #:package "pkg-mfail" #:slot "default"
                #:manifest mfile2 #:manifest-entry synth-entry))
  (check-equal? (manifest-read mfile2) (list seed-entry))
  ;; Without manifest args the run succeeds journaled, nothing to write.
  (parameterize ([current-fake-log (box '())])
    (apply-plan mplan "hm2" fake-perform!
                #:state state #:package "pkg-noman" #:slot "default"))
  (check-equal? (length (journal-completions state "pkg-noman" "default"))
                1)

  ;; --- pm-apply end to end on synthetic git fixtures (D-040) ---
  ;; Two local repos, beta depending on alpha. No network, no real
  ;; packages; the vault, state, prefix and manifest all live under
  ;; one temp root that is deleted at the end.
  ;;
  ;; --- why every case below narrates (D-041) ---
  ;; This block once went 41 minutes with no output at all: parked in
  ;; the runtime poll with 100+ leaked pipe fds, no child, no write, no
  ;; event. A silent region and a hang look identical from outside, and
  ;; "the last line printed" was the only thing anyone had. So every
  ;; case boundary, and every cleanup, now says what it is about to do,
  ;; and every boundary counts the fds and threads it inherited. The
  ;; census is the cheap half: run.rkt leaks three pipe fds per
  ;; subprocess call (proved: 120 calls move /proc/self/fd by exactly
  ;; 360, and a GC reclaims none of them), so a rising number here is
  ;; that leak, and a flat one is a flat one.
  (define (proc-count p)
    (with-handlers ([exn:fail? (lambda (_) "?")])
      (number->string (length (directory-list p)))))

  (define (e2e-census tag)
    (step 'e2e (string-append "census " tag)
          "a park in the next region has to be attributable, so what it inherits is counted first"
          #:how (format "fds=~a threads=~a"
                        (proc-count "/proc/self/fd")
                        (proc-count "/proc/self/task"))))

  ;; tag why thunk -> any: one narrated e2e case, start to finish.
  (define (e2e-case tag why thunk)
    (e2e-census (string-append "before " tag))
    (define result
      (wait-for 'e2e tag why #:how "the whole case, every spawn inside it" thunk))
    (e2e-census (string-append "after " tag))
    result)

  ;; tag dir -> void: a narrated cleanup. Deleting a fixture tree walks
  ;; real git objects and is a genuine wait, so it says which tree.
  (define (e2e-cleanup tag dir)
    (wait-for 'e2e tag
              "a fixture tree left behind is a tree the next run inherits"
              #:how (format "remove ~a" dir)
              (lambda ()
                (when (directory-exists? dir)
                  (delete-directory/files dir))
                (void))))

  (define e2e-root
    (build-path (find-system-path 'temp-dir) "pm-apply-e2e"))
  (e2e-cleanup "e2e-root-stale" e2e-root)
  (make-directory* e2e-root)
  (e2e-census "after e2e-root reset")
  (define e2e-home (build-path e2e-root "home"))
  (make-directory e2e-home)
  (define (e2e-git dir . args)
    (define res
      (run-command (git-executable-path) args
                   #:cwd (path->string dir)
                   #:kind 'fetch #:operation "apply-e2e-fixture"
                   #:env (list (cons "GIT_AUTHOR_NAME" "t")
                               (cons "GIT_AUTHOR_EMAIL" "t@t")
                               (cons "GIT_COMMITTER_NAME" "t")
                               (cons "GIT_COMMITTER_EMAIL" "t@t")
                               (cons "HOME" (path->string e2e-home))
                               (cons "GIT_CONFIG_NOSYSTEM" "1"))))
    (unless (zero? (run-result-exit res))
      (error 'apply-e2e "git failed: ~a" args))
    res)
  (define (e2e-upstream name)
    (define d (build-path e2e-root name))
    (make-directory d)
    (e2e-git d "init" "-b" "main" ".")
    (call-with-output-file (build-path d "f.txt")
      (lambda (out)
        (displayln "F" out)))
    (e2e-git d "add" "-A")
    (e2e-git d "commit" "-qm" "init")
    ;; ONE list, not two values. A narration wrapper (wait-for, like
  ;; with-op) keeps only the first of a thunk's values, so returning a
  ;; pair and destructuring afterwards silently lost the pin. A list
  ;; survives narration intact, which is why this returns (list dir pin).
  (list d
        (car (run-result-stdout-lines
               (e2e-git d "rev-parse" "HEAD")))))
  ;; The fixture repos are made with four git spawns each. Narrated as one
  ;; case so a park in a fixture git call is attributable too.
  (define e2e-up-a-list
    (e2e-case "fixture up-a"
              "no pin exists until the upstream repo has a commit to point at"
              (lambda () (e2e-upstream "up-a"))))
  (define e2e-up-a (car e2e-up-a-list))
  (define e2e-pin-a (cadr e2e-up-a-list))
  (define e2e-up-b-list
    (e2e-case "fixture up-b"
              "no pin exists until the upstream repo has a commit to point at"
              (lambda () (e2e-upstream "up-b"))))
  (define e2e-up-b (car e2e-up-b-list))
  (define e2e-pin-b (cadr e2e-up-b-list))
  (define e2e-specs (build-path e2e-root "specs"))
  (make-directory e2e-specs)
  (define (e2e-write-spec dir name ver deps pin up prog extra-install)
    (call-with-output-file (build-path dir (string-append name ".rktd"))
      (lambda (out)
        (displayln
          (string-append
            "(spec (format-version 2) (name " name ")"
            " (version \"" ver "\")"
            " (summary \"synthetic " name "\")"
            " (source (git \"" up "\" \"" pin "\"))"
            " (deps " deps ")"
            " (build (steps (run #:argv (\"sh\" \"-c\" \"cp f.txt g.txt\") #:dir \".\")))"
            " (install (prefix (bin \"g.txt\" \"bin/"
            prog
            "\")"
            extra-install "))"
            " (license mit)"
            " (homepage \"https://example.invalid/\"))")
          out))))
  (e2e-write-spec e2e-specs "pkg-alpha" "1.0.0" "()" e2e-pin-a
                  (string-append "file://" (path->string e2e-up-a))
                  "prog" "")
  (e2e-write-spec e2e-specs "pkg-beta" "1.0.0" "((pkg-alpha \"1.0.0\"))"
                  e2e-pin-b
                  (string-append "file://" (path->string e2e-up-b))
                  "beta-prog" "")
  (define e2e-state (path->string (build-path e2e-root "state")))
  (define e2e-prefix (path->string (build-path e2e-root "prefix")))
  (define e2e-vault (path->string (build-path e2e-root "vault.git")))
  (define e2e-manifest (path->string (build-path e2e-state "manifest.rktd")))
  ;; Simple on purpose. pm-apply answers ONE value (the rows), so the
  ;; narration wraps that value and there is no multi-value plumbing to
  ;; get wrong. An earlier version routed the result through a box and
  ;; call-with-values to survive a wrapper that keeps only the first
  ;; value; that was defending against a problem this call site does not
  ;; have, and the box is what broke it.
  (define (e2e-live #:state state #:manifest manifest #:prefix prefix
                    #:case tag)
    (define rows
      (parameterize ([current-allow-file-urls #t])
        (pm-apply (path->string e2e-specs)
                  #:state state
                  #:manifest manifest
                  #:prefix prefix
                  #:vault e2e-vault)))
    (e2e-case tag
              "the installed tree is not inspectable until this apply has returned"
              (lambda () rows)))
  ;; (a) dry run prints the plan and touches nothing.
  (define dry-plans
    (e2e-case "(a) dry-run"
              "nothing later here is meaningful unless the dry run renders and changes nothing"
              (lambda ()
                (parameterize ([current-allow-file-urls #t])
                  (pm-apply-dry (path->string e2e-specs))))))
  (check-equal? (map first dry-plans) '("pkg-alpha" "pkg-beta"))
  (check-true (andmap (lambda (p) (> (string-length (second p)) 0))
                      dry-plans))
  (check-false (directory-exists? (build-path e2e-state "store")))
  ;; (b) live run installs in resolve order with modes, links, journal.
  (define live-results
    (e2e-live #:state e2e-state #:manifest e2e-manifest #:prefix e2e-prefix
              #:case "(b) live install"))
  (check-equal? (map first live-results) '("pkg-alpha" "pkg-beta"))
  (check-equal? (map second live-results) '(applied applied))
  (define (e2e-installed prefix name prog)
    (check-true (link-exists? (build-path prefix name "current")))
    (define cur (resolve-path (build-path prefix name "current")))
    (check-equal? (file->string (build-path cur "bin" prog)) "F\n")
    cur)
  (e2e-installed e2e-prefix "pkg-alpha" "prog")
  (e2e-installed e2e-prefix "pkg-beta" "beta-prog")
  (define mans
    (wait-for 'e2e "(b) manifest-read"
              "the declared entries are only known once the manifest has been read back"
              #:how (format "read ~a" e2e-manifest)
              (lambda ()
                (parameterize ([current-allow-file-urls #t])
                  (manifest-read e2e-manifest)))))
  (check-equal? (sort (map manifest-entry-name mans) string<?)
                '("pkg-alpha" "pkg-beta"))
  ;; (c) second run is a pure SKIP no-op with every reason listed.
  (define rerun-results
    (e2e-live #:state e2e-state #:manifest e2e-manifest #:prefix e2e-prefix
              #:case "(c) rerun is a pure skip"))
  (check-equal? (map second rerun-results) '(skipped skipped))
  (for ([r (in-list rerun-results)])
    (check-true (> (length (third r)) 0))
    (for ([row (in-list (third r))])
      (check-equal? (second row) 'skipped)
      (check-regexp-match #rx"matches the journal" (fourth row))))
  ;; (d) cancel stops before anything is performed; rerun completes.
  (define e2e-state2 (path->string (build-path e2e-root "state2")))
  (define e2e-prefix2 (path->string (build-path e2e-root "prefix2")))
  (define e2e-manifest2
    (path->string (build-path e2e-state2 "manifest.rktd")))
  (define e2e-cancel-box (make-channel))
  (channel-put e2e-cancel-box 'stop-now)
  (define e2e-cancel-err
    (e2e-case "(d) cancel before any step"
              "nothing is installed until this apply has decided to stop"
              (lambda ()
                (with-handlers ([exn:fail:pm? (lambda (e) e)])
                  (parameterize ([current-allow-file-urls #t])
                    (pm-apply (path->string e2e-specs)
                              #:state e2e-state2
                              #:manifest e2e-manifest2
                              #:prefix e2e-prefix2
                              #:vault e2e-vault
                              #:cancel e2e-cancel-box))
                  'no-error))))
  (check-pred cancelled-error? e2e-cancel-err)
  (check-false (directory-exists? (build-path e2e-prefix2 "pkg-alpha")))
  (define after-cancel-results
    (e2e-live #:state e2e-state2
              #:manifest e2e-manifest2
              #:prefix e2e-prefix2
              #:case "(d) rerun after cancel"))
  (check-equal? (map second after-cancel-results) '(applied applied))
  ;; (e) a changed input hash reruns the affected steps.
  (e2e-write-spec e2e-specs "pkg-alpha" "1.0.1" "()" e2e-pin-a
                  (string-append "file://" (path->string e2e-up-a))
                  "prog" "")
  (e2e-write-spec e2e-specs "pkg-beta" "1.0.0" "((pkg-alpha \"1.0.1\"))"
                  e2e-pin-b
                  (string-append "file://" (path->string e2e-up-b))
                  "beta-prog" "")
  (define bumped-results
    (e2e-live #:state e2e-state #:manifest e2e-manifest #:prefix e2e-prefix
              #:case "(e) changed input hash reruns"))
  (check-equal? (map second bumped-results) '(applied applied))
  ;; (f) a failing check leaves the marker and the old current alone.
  (define e2e-state3 (path->string (build-path e2e-root "state3")))
  (define e2e-prefix3 (path->string (build-path e2e-root "prefix3")))
  (define e2e-manifest3
    (path->string (build-path e2e-state3 "manifest.rktd")))
  (define e2e-specs-ok (build-path e2e-root "specs-ok"))
  (make-directory e2e-specs-ok)
  (e2e-write-spec e2e-specs-ok "pkg-gamma" "1.0.0" "()" e2e-pin-a
                  (string-append "file://" (path->string e2e-up-a))
                  "prog" "")
  (define (e2e-apply-gamma specs-dir tag)
    (e2e-case tag
              "gamma's store and current link are only inspectable once this apply has returned"
              (lambda ()
                (parameterize ([current-allow-file-urls #t])
                  (pm-apply (path->string specs-dir)
                            #:state e2e-state3
                            #:manifest e2e-manifest3
                            #:prefix e2e-prefix3
                            #:vault e2e-vault)))))
  (e2e-apply-gamma e2e-specs-ok "(f) gamma installs clean")
  (define good-current
    (resolve-path (build-path e2e-prefix3 "pkg-gamma" "current")))
  (define e2e-specs-bad (build-path e2e-root "specs-bad"))
  (make-directory e2e-specs-bad)
  (e2e-write-spec e2e-specs-bad "pkg-gamma" "1.0.1" "()" e2e-pin-a
                  (string-append "file://" (path->string e2e-up-a))
                  "prog" " (check \"sh\" \"-c\" \"exit 1\")")
  (define bad-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (e2e-apply-gamma e2e-specs-bad "(f) gamma fails its check")
      'no-error))
  (check-pred build-error? bad-err)
  (check-equal? (resolve-path (build-path e2e-prefix3 "pkg-gamma" "current"))
                good-current)
  (define bad-versioned
    (build-path e2e-state3 "store" "pkg-gamma" "default"))
  (define bad-gens (directory-list bad-versioned))
  (check-equal? (length bad-gens) 2)
  (define new-gen
    (for/first ([g (in-list bad-gens)]
                #:unless (equal? (path->string g)
                                 (path->string
                                   (file-name-from-path good-current))))
      g))
  (check-true
    (file-exists? (build-path bad-versioned new-gen ".pm-incomplete")))
  ;; (g) a second concurrent apply is refused naming the holder.
  (define busy-err
    (e2e-case "(g) second writer refused"
              "the refusal only means something once the inner apply has had its chance"
              (lambda ()
                (with-handlers ([exn:fail:pm? (lambda (e) e)])
                  (call-with-vault-lock e2e-state
                                        "holder"
                                        "test holds the lock"
                                        (lambda ()
                                          (e2e-live #:state e2e-state
                                                    #:manifest e2e-manifest
                                                    #:prefix e2e-prefix
                                                    #:case "(g) inner apply")))
                  'no-error))))
  (check-pred exn:fail:pm? busy-err)
  (check-regexp-match #rx"holder" (exn-message busy-err))
  ;; The two cleanups are narrated for the same reason the cases are: a
  ;; park in a delete-directory over a real git tree used to be
  ;; indistinguishable from a park in an apply. This tree also holds a
  ;; `current` symlink pointing back into itself, so the walk has more to
  ;; resolve than a plain tree does.
  (e2e-cleanup "(z) e2e-root teardown" e2e-root)
  (e2e-cleanup "(z) state-root teardown" state-root)
  )
