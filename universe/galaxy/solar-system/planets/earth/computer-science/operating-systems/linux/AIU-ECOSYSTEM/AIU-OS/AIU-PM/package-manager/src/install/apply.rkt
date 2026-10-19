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
;; mid-step. One writer lock (E-12c, G-02): #:writer (id note) takes
;; ./closure-lock.rkt's try-only lock on the install root first,
;; failing fast naming the holder; try-only never blocks, so it is
;; safe even in-process (P-04). pm-apply takes the SAME lock, and
;; takes it before the first thing that changes the machine, so the
;; lock covers the whole closure rather than one package: what is
;; inside it and what is deliberately outside is written out in
;; closure-lock.rkt's header. Readers (journal queries) never lock;
;; jobs keep queue-time concerns. #:manifest + #:manifest-entry upsert the
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
         "../queue/journal.rkt"
         "./local-perform.rkt"
         "../store/manifest.rkt"
         "../store/query.rkt"
         "../git/vault.rkt"
         "../errors/error-type.rkt"
         "../store/lockfile.rkt"
         "../spec/plan.rkt"
         "../machine/directories.rkt"
         "../spec/spec.rkt"
         "../spec/spec-read.rkt"
         "./closure-lock.rkt"
         "../narration/narration.rkt"
         "../spec/version.rkt")

(provide
 (contract-out
  ;; plan string performer -> void, journaled run, resume by hash.
  ;; #:writer (id note) takes the install root's closure lock first.
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
    ;; G-07: a landed step is not re-verified and not re-applied, and
    ;; the SKIP says WHERE the landed record is, not only that it
    ;; landed. A reader who asks "why was this not performed" gets the
    ;; input hash AND the journal entry it was read from, so the skip
    ;; is checkable rather than merely asserted.
    (define journal-entry
      (path->string (journal-file state package slot)))
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
                            step-id
                            (format
                             "input hash ~a already landed in ~a as ~a"
                             input-hash journal-entry step-id))
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
      ;; G-02: one apply holds one install root's closure for the whole
      ;; pass, taken before the first step and released after the last,
      ;; so a second apply on the same root cannot interleave anywhere
      ;; inside it. The lock is try-only, so the refusal is immediate
      ;; and names the holder; D-041 is why the attempt below says
      ;; itself before it is made.
      (wait-for 'apply "closure-lock"
                "only one apply may touch one install root, so the lock comes before any step"
                #:how (format "lock the closure at ~a as ~a" state (first writer))
                (lambda ()
                  (call-with-closure-lock state (first writer) (second writer) run)))
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
  ;; Check the declaration directory BEFORE narrating the scan. Without
  ;; this, a path that does not exist escaped as a raw
  ;; "directory-list: could not open directory" from deep inside the
  ;; listing: not a refusal, no rule named, and on the MCP surface it
  ;; became an internal error that blamed the server for the caller's
  ;; typo. A missing or wrong-shaped declaration directory is a refusal
  ;; that names what was expected and what was given.
  (define specs-path (if (path? specs-dir) (path->string specs-dir)
                         (format "~a" specs-dir)))
  (cond
    [(not (directory-exists? specs-path))
     ;; one refusal covers both "missing" and "is a file": either way it
     ;; is not a directory of specs, and the caller needs the same fix
     (raise-pm-error 'config 'scan-specs "specs directory not found"
                     #:fields `(("specs" . ,specs-path))
                     #:hint "point the command at a directory of .rktd spec files")])
  (with-op 'scan specs-path
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
;; failure. G-02: the closure lock is taken BEFORE the first thing
;; this run changes and released after the last, so a second apply on
;; the same install root is refused at once, naming the holder,
;; instead of interleaving anywhere inside the first one. A dry run
;; takes no lock and makes no directories: it changes nothing, so
;; there is nothing for another apply to interleave with
;; (closure-lock.rkt states the whole scope from the lock's side).
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
  (with-op 'apply (as-dir specs-dir)
           (if dry-run "the plan is shown and nothing changes"
               "every package installs in resolve order")
           (lambda ()
             (cond
               [dry-run (dry-run-rows specs-dir vault-git lock)]
               [else
                ;; D-041: the attempt says itself before it is made.
                ;; The closure lock is try-only so this cannot block,
                ;; and "cannot block" is a claim the feed keeps.
                (wait-for 'apply "closure-lock"
                          "only one apply may touch one install root, so the lock comes first"
                          #:how (format "lock the closure at ~a as pm-apply" state-dir)
                          (lambda ()
                            (call-with-closure-lock
                             state-dir "pm-apply" (format "apply ~a" specs-dir)
                             (lambda ()
                               (live-apply specs-dir lock state-dir manifest-path
                                            prefix-dir vault-git cancel)))))]))))

;; specs-dir vault lock -> results. The dry branch of pm-apply: scan
;; the declarations, compare them to the lockfile, derive, and report
;; what each package would be. No state root, no prefix dirs, no vault
;; write and no lock -- a dry run changes nothing, so there is nothing
;; in it for another apply to interleave with (D-040).
(define (dry-run-rows specs-dir vault lock)
  (define specs (scan-specs specs-dir vault #:preflight #f))
  (when lock
    (step 'apply "lock"
          "the declaration must agree with the lockfile")
    (check-lock specs lock))
  (define pps (resolve-and-derive specs))
  (for/list ([pp (in-list pps)])
    (list (symbol->string (package-plan-name pp))
          'planned
          '())))

;; specs-dir lock state manifest prefix vault cancel -> results. The
;; whole live apply, every part of which the caller's closure lock
;; already covers (G-02): the state root, the empty vault, the specs
;; scan and its per-package preflight, the prefix dirs, the lockfile
;; comparison, the resolve, and then each package's journalled steps
;; in resolve order. This function takes no lock of its own: a second
;; acquisition would refuse against this same run.
(define (live-apply specs-dir lock state manifest prefix vault cancel)
  (wait-for 'apply "state-dir"
            "the state root must exist before a journal or a store dir can live under it"
            #:how (format "create ~a" state)
            (lambda ()
              (make-directory* state)
              (void)))
  (unless (directory-exists? vault)
    (step 'apply "vault-init"
          "the vault does not exist yet, so it is created empty")
    (define vault-parent
      (or (path-only (string->path vault))
          (string->path vault)))
    (wait-for 'apply "vault-init"
              "the empty vault cannot exist until git has made the bare repo"
              #:how (format "vault-init ~a" vault)
              (lambda ()
                (make-directory* vault-parent)
                (vault-init vault))))
  ;; scan-specs narrates its own dir listing, per-spec reads and
  ;; per-package vault preflight, so this only names the phase.
  (define specs (scan-specs specs-dir vault #:preflight #t))
  (wait-for 'apply "prefix-dirs"
            "each package needs its own prefix dir before a current link can land there"
            #:how (format "create ~a/<package>" prefix)
            (lambda ()
              (for ([s (in-list specs)])
                (make-directory*
                 (build-path prefix (symbol->string (spec-name s)))))
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
  (define by-name
    (for/hash ([s (in-list specs)])
      (values (symbol->string (spec-name s)) s)))
  (for/list ([pp (in-list pps)])
    (define pkg-name (symbol->string (package-plan-name pp)))
    (wait-for 'apply
              (format "apply-package ~a" pkg-name)
              "one package is fully installed before the next one starts"
              #:how (format "package-plan slot ~a"
                            (symbol->string (package-plan-slot pp)))
              (lambda ()
                (apply-one pp (hash-ref by-name pkg-name)
                           state manifest prefix vault cancel)))))

;; path-or-string -> string
(define (as-dir d)
  (if (path? d) (path->string d) (format "~a" d)))

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
            ;; G-07: the row says WHICH hash and WHICH journal
            ;; entry, so a row is enough to check the skip without
            ;; re-reading the journal by hand.
            [else (list id 'skipped 0
                        (format "input hash ~a matches the journal entry ~a"
                                input-hash
                                (path->string
                                 (journal-file state name slot))))])))
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
