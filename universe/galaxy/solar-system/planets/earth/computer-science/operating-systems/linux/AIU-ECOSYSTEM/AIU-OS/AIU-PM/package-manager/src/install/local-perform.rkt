#lang racket/base
;; local.rkt -- the real-effects backend: interprets plans inside a prefix.
;; Every install path resolves inside the prefix (F-7); file writes are
;; atomic (F-3); removes are idempotent (F-6). Stops at first failure.
;; Fetch establishes sources (clone/fetch plus pin); extract materializes
;; a previously pinned commit using the #:commit context. Run steps and
;; staging live wherever the plan says; only install paths are confined.

(require racket/contract/base
         racket/file
         racket/path
         racket/string
         "../process/run.rkt"
         "../git/git-repo.rkt"
         "../store/store.rkt"
         "../git/vault.rkt"
         "../errors/error-type.rkt"
         "../security/security.rkt"
         "../spec/plan.rkt"
         "../narration/narration.rkt")

(provide
 (contract-out
  ;; plan -> void, interprets every action in order (stops at failure)
  ;; #:prefix gates all install paths; #:commit feeds extract pins;
  ;; #:vault answers export-action namespaces
  [local-perform! (->* (plan?)
                       (#:prefix (or/c path-string? #f)
                        #:commit (or/c string? #f)
                        #:vault (or/c path-string? #f))
                       void?)]
  ;; action prefix commit vault -> void, one action for real. Exported
  ;; so apply-plan performers can track and time each action; the
  ;; interpreter stays dumb either way.
  [perform-action! (-> action?
                       (or/c path-string? #f)
                       (or/c string? #f)
                       (or/c path-string? #f)
                       void?)]))

;; ---------------------------------------------------------------------------
;; Confinement and error shaping

;; path-string -> path, absolute simplified (relative resolves at cwd)
(define (absolute-path p)
  (simplify-path (path->complete-path p)))

;; path-string string path-string -> path, inside prefix or config error
(define (confine prefix what p)
  (define pre-text (path->string (absolute-path prefix)))
  (define abs-text (path->string (absolute-path p)))
  ;; S-01: containment is the policy's question, not a local idiom.
  (if (path-contained? pre-text abs-text)
      (string->path abs-text)
      (raise-pm-error 'config 'local-perform! "path escapes the prefix"
                      #:fields `(("field" . ,what)
                                 ("path" . ,abs-text)
                                 ("prefix" . ,pre-text)))))

;; string (listof pair) (-> any) -> any, raw faults become install errors
(define (with-install-errors what fields thunk)
  (with-handlers ([exn:fail:filesystem?
                   (lambda (e)
                     (raise-pm-error 'install 'local-perform! what
                                     #:fields fields #:cause e))])
    (thunk)))

;; (or/c path-string #f) action -> path-string, prefix or config error
(define (need-prefix prefix a)
  (or prefix
      (raise-pm-error 'config 'local-perform! "prefix not configured"
                      #:hint "pass #:prefix for install actions")))

;; ---------------------------------------------------------------------------
;; Source actions (vault paths ride in the plan as data, A-3)

;; fetch-action -> void, clone-or-fetch the mirror plus pin (F-2, D-012)
(define (perform-fetch! a)
  (define mirror (fetch-action-dest a))
  (define parent
    (let-values ([(base _name _dir?) (split-path mirror)]) base))
  (cond [(or (directory-exists? mirror)
             (file-exists? mirror)
             (link-exists? mirror))
         (git-fetch-mirror mirror)]
        [else
         (when (and parent (not (directory-exists? parent)))
           (make-directory* parent))
         (git-clone-mirror (fetch-action-url a) mirror)])
  (git-pin-commit mirror (fetch-action-commit a)))

;; extract-action (or/c string #f) -> void, pin plus export to staging
(define (perform-extract! a commit)
  (unless commit
    (raise-pm-error 'config 'local-perform! "extract needs a pin"
                    #:fields `(("action" . "extract"))
                    #:hint "pass #:commit from the lockfile pin"))
  (define staging (extract-action-dest a))
  (unless (directory-exists? staging)
    (with-install-errors "cannot prepare staging"
                         `(("staging" . ,staging))
      (lambda () (make-directory* staging))))
  (git-export-commit (extract-action-src a) commit staging))

;; run-step-action -> void, exact argv through the runner (F-2, E-8)
(define (perform-run-step! a)
  (define argv (run-step-action-argv a))
  (define exe (find-executable-path (car argv)))
  (unless exe
    (raise-pm-error 'config 'local-perform! "step executable not found"
                    #:fields `(("exe" . ,(car argv))
                               ("step" . ,(run-step-action-name a)))))
  (unless (directory-exists? (run-step-action-cwd a))
    (raise-pm-error 'config 'local-perform! "step directory missing"
                    #:fields `(("step" . ,(run-step-action-name a))
                               ("directory" . ,(run-step-action-cwd a)))))
  (define res
    (spawn-and-wait exe (cdr argv)
                 #:cwd (run-step-action-cwd a)
                 #:kind 'build
                 #:operation (run-step-action-name a)))
  (unless (zero? (result-exit res))
    (raise-pm-error 'build 'local-perform! "step failed"
                    #:fields `(("step" . ,(run-step-action-name a))
                               ("command" . ,(string-join argv " "))
                               ("directory" . ,(run-step-action-cwd a))
                               ("exit-code"
                                . ,(number->string (result-exit res)))
                               ("stderr" . ,(string-join
                                             (result-stderr-lines res)
                                             "\n"))))))

;; ---------------------------------------------------------------------------
;; Install actions (all paths confined; F-7, F-10)

;; install-file-action path-string -> void, confined copy plus mode
(define (perform-install-file! a prefix)
  (define dest (confine prefix "dest" (install-file-action-dest a)))
  (define src (install-file-action-src a))
  (with-install-errors "install copy failed"
                       `(("src" . ,src)
                         ("dest" . ,(path->string dest)))
    (lambda ()
      (define parent
        (let-values ([(base _n _d) (split-path dest)]) base))
      (unless (directory-exists? parent)
        (make-directory* parent))
      (when (link-exists? dest)
        (delete-file dest))
      (when (file-exists? dest)
        (delete-file dest))
      (copy-file src dest)
      (file-or-directory-permissions dest (install-file-action-mode a))
      (void))))

;; write-file-action path-string -> void, confined atomic write (F-3)
(define (perform-write-file! a prefix)
  (define dest (confine prefix "path" (write-file-action-path a)))
  (with-install-errors "install write failed"
                       `(("path" . ,(path->string dest)))
    (lambda ()
      (define parent
        (let-values ([(base _n _d) (split-path dest)]) base))
      (unless (directory-exists? parent)
        (make-directory* parent))
      (call-with-atomic-output-file dest
        (lambda (out _tmp)
          (display (write-file-action-content a) out))))))

;; symlink-action path-string -> void, confined link, resolved inside
(define (perform-symlink! a prefix)
  (define link (confine prefix "link" (symlink-action-link a)))
  (define raw-target (symlink-action-target a))
  (define link-dir
    (let-values ([(base _n _d) (split-path link)]) base))
  (define abs-text
    (if (string-prefix? raw-target "/")
        raw-target
        (path->string (build-path link-dir raw-target))))
  (define pre-text (path->string (absolute-path prefix)))
  (define resolved (resolve-fully (string->path abs-text)))
  ;; S-01: the policy answers once for the resolved target; the arms
  ;; below only word the refusal, so escape and dangling keep their
  ;; own messages without re-deciding containment.
  (define target-ok?
    (and resolved
         (symlink-target-ok? pre-text
                             (path->string resolved)
                             (or (file-exists? resolved)
                                 (directory-exists? resolved)))))
  (cond [(not resolved)
         (raise-pm-error 'config 'local-perform! "symlink loop detected"
                         #:fields `(("link" . ,(path->string link))))]
        [(and resolved
              (not (or (file-exists? resolved) (directory-exists? resolved))))
         (raise-pm-error 'config 'local-perform! "dangling symlink"
                         #:fields `(("link" . ,(path->string link))
                                    ("target" . ,raw-target)))]
        [(not target-ok?)
         (raise-pm-error 'config 'local-perform!
                         "symlink escapes the prefix"
                         #:fields `(("link" . ,(path->string link))
                                    ("target" . ,raw-target)))]
        [else
         (with-install-errors "install symlink failed"
                              `(("link" . ,(path->string link))
                                ("target" . ,raw-target))
           (lambda ()
             (cond [(link-exists? link) (delete-file link)]
                   [(or (file-exists? link) (directory-exists? link))
                    (raise-pm-error 'config 'local-perform!
                                    "link path occupied"
                                    #:fields `(("link" . ,(path->string
                                                           link))))]
                   [else (void)])
             (make-file-or-directory-link raw-target link)))]))

;; remove-path-action path-string -> void, confined idempotent remove
(define (perform-remove-path! a prefix)
  (define target (confine prefix "path" (remove-path-action-path a)))
  (define pre-text (path->string (absolute-path prefix)))
  (when (string=? (path->string target) pre-text)
    (raise-pm-error 'config 'local-perform! "refuses the prefix itself"
                    #:fields `(("path" . ,(path->string target)))))
  (with-install-errors "install remove failed"
                       `(("path" . ,(path->string target)))
    (lambda ()
      (cond [(or (link-exists? target) (file-exists? target))
             (delete-file target)]
            [(directory-exists? target)
             (delete-directory/files target)]
            [else (void)]))))

;; ---------------------------------------------------------------------------
;; E-11 actions (state shaping plus check; all reused, none silent)

;; export-action (or/c path-string #f) -> void, vault pin to staging.
;; The vault root rides alongside #:commit as plan data context (A-3):
;; the action carries what to export, the caller says from where.
(define (perform-export! a vault)
  (define vault-git
    (or vault
        (raise-pm-error 'config 'local-perform! "export needs a vault"
                        #:fields `(("action" . "export"))
                        #:hint "pass #:vault holding vault.git")))
  (vault-export-commit vault-git
                       (symbol->string (export-action-package a))
                       (export-action-pin a)
                       (export-action-dest a)))

;; check-action -> void, exact argv in cwd, exit 0 required. A failing
;; check fails the build (SPEC-NEUTRAL section 3, exit 7): kind 'build
;; with the step name and exit code, never silent. Exe resolution
;; mirrors build.rkt spawn-build!: slash names resolve under cwd.
(define (perform-check! a)
  (define argv (check-action-argv a))
  (define cwd (check-action-cwd a))
  (define exe0 (car argv))
  (define exe
    (if (regexp-match? #rx"/" exe0)
        (let ([p (if (absolute-path? (string->path exe0))
                     (string->path exe0)
                     (build-path cwd exe0))])
          (if (file-exists? p)
              p
              (raise-pm-error 'config 'local-perform!
                              "check executable not found"
                              #:fields `(("exe" . ,exe0)
                                          ("step" . "check")))))
        (or (find-executable-path exe0)
            (raise-pm-error 'config 'local-perform!
                            "check executable not found"
                            #:fields `(("exe" . ,exe0)
                                        ("step" . "check"))))))
  (unless (directory-exists? cwd)
    (raise-pm-error 'config 'local-perform! "check directory missing"
                    #:fields `(("step" . "check")
                                ("directory" . ,cwd))))
  (define res
    (spawn-and-wait exe (cdr argv)
                 #:cwd cwd
                 #:kind 'build
                 #:operation "check"))
  (unless (zero? (result-exit res))
    (raise-pm-error 'build 'local-perform! "check failed"
                    #:fields `(("step" . "check")
                                ("command" . ,(string-join argv " "))
                                ("directory" . ,cwd)
                                ("exit-code"
                                 . ,(number->string (result-exit res)))
                                ("stderr" . ,(string-join
                                              (result-stderr-lines res)
                                              "\n"))))))

;; mark-incomplete-action -> void, the marker appears (store owns it)
(define (perform-mark! a)
  (with-install-errors "cannot mark incomplete"
                       `(("dir" . ,(mark-incomplete-action-dir a)))
    (lambda ()
      (mark-store-dir (mark-incomplete-action-dir a))
      (void))))

;; clear-incomplete-action -> void, the marker goes (store owns it)
(define (perform-clear! a)
  (with-install-errors "cannot clear incomplete"
                       `(("dir" . ,(clear-incomplete-action-dir a)))
    (lambda ()
      (clear-store-marker (clear-incomplete-action-dir a))
      (void))))

;; set-current-action -> void, atomic flip (store owns it)
(define (perform-set-current! a)
  (with-install-errors "cannot flip current"
                       `(("target" . ,(set-current-action-target a))
                         ("link" . ,(set-current-action-link a)))
    (lambda ()
      (swap-link! (set-current-action-target a)
                  (set-current-action-link a))
      (void))))

;; ---------------------------------------------------------------------------
;; Entry point (A-3: the executor is a dumb interpreter)

;; action (or/c path-string #f) (or/c string #f) (or/c path-string #f)
;; -> void; vault answers export-action, commit answers extract-action
(define (perform-action! a prefix commit vault)
  (cond [(fetch-action? a) (perform-fetch! a)]
        [(export-action? a) (perform-export! a vault)]
        [(check-action? a) (perform-check! a)]
        [(mark-incomplete-action? a) (perform-mark! a)]
        [(clear-incomplete-action? a) (perform-clear! a)]
        [(set-current-action? a) (perform-set-current! a)]
        [(extract-action? a) (perform-extract! a commit)]
        [(run-step-action? a) (perform-run-step! a)]
        [(install-file-action? a)
         (perform-install-file! a (need-prefix prefix a))]
        [(write-file-action? a)
         (perform-write-file! a (need-prefix prefix a))]
        [(symlink-action? a)
         (perform-symlink! a (need-prefix prefix a))]
        [(remove-path-action? a)
         (perform-remove-path! a (need-prefix prefix a))]
        [else (raise-pm-error 'internal 'local-perform! "not an action"
                              #:fields `(("value" . ,a)))]))

;; plan -> void, interprets every action in order (stops at failure)
;; path-or-string -> string, for an event field.
(define (as-text x)
  (if (path? x) (path->string x) (format "~a" x)))

(define (local-perform! p #:prefix [prefix #f] #:commit [commit #f]
                          #:vault [vault #f])
  ;; D-036: this is where a plan's actions become real files on this
  ;; machine, so it is one narrated operation with one step per action.
  (with-op 'install (if prefix (as-text prefix) "(no prefix)")
           "the plan's actions are performed against this machine"
           #:how (if commit (format "commit ~a" commit) "no commit given")
           #:inputs (list (number->string (length (plan-actions p))))
           (lambda ()
             (for ([a (in-list (plan-actions p))])
               (step 'install (format "action ~a" a)
                     "the next action of the plan, performed for real")
               (perform-action! a prefix commit vault)))))

;; ---------------------------------------------------------------------------
