#lang racket/base
;; dispatch.rkt -- the command line dispatcher: the command structs and
;; their parser, the renderers (sexp and json), the check runner, the
;; entries builder that feeds activate and remove, command-json
;; (the exact --format json document), and run-cli, the executable
;; entry that turns argv into an exit code. Thin over the core verbs;
;; every failure becomes an exit code here (E-5 narrow handlers, the
;; codes in docs/ERRORS.org), and unwired commands refuse loudly.

(require racket/file
         racket/list
         racket/port
         racket/string
         json
         "../machine/cancel.rkt"
         "../errors/error-type.rkt"
         "../spec/spec.rkt"
         "../spec/spec-read.rkt"
         "../narration/print-console.rkt"
         "../narration/narration.rkt"
         "./version.rkt"
         "../machine/file-lock.rkt"
         "../spec/plan.rkt"
         "../store/query.rkt"
         "../store/update.rkt"
         "../install/apply.rkt"
         "../install/activate.rkt"
         "../store/manifest.rkt"
         "./documents.rkt")

(provide (struct-out command-check)
         (struct-out command-help)
         (struct-out command-plan)
         (struct-out command-lock)
         (struct-out command-fetch)
         (struct-out command-apply)
         (struct-out command-update)
         (struct-out command-activate)
         (struct-out command-rollback)
         (struct-out command-remove)
         (struct-out command-hold)
         (struct-out command-why)
         (struct-out command-owner)
         (struct-out command-verify)
         (struct-out command-status)
         (struct-out command-held)
         (struct-out command-outdated)
         command?
         parse-args
         command->sexp
         command->json
         run-check
         command-json
         run-cli
         command-table
         profile-entries)

;; Commands (data, like everything crossing a boundary here)

(struct command-check (dir format) #:transparent)
;; dir    : string?  directory holding .rktd files (as given on argv)
;; format : (or/c 'sexp 'json), output shape; rendering per format arrives
;;          with E-18, parsing lands here (E-01)

(struct command-help () #:transparent)
;; no fields: print help text

(struct command-plan (specs format) #:transparent)
;; specs  : string?  specs directory; format as in command-check
(struct command-lock (lockfile format) #:transparent)
;; lockfile : string?  lockfile path
(struct command-fetch (manifest format) #:transparent)
;; manifest : string?  declaration manifest path
;; D-040. specs is the declaration directory to apply FROM. `lock` is
;; the lockfile the declaration must agree with, or #f to skip that
;; check. `confirm` is the human gate: #f prints the full plan and
;; changes NOTHING, #t is the only way the machine changes. There is no
;; third value and no way to set it from the environment.
(struct command-apply (specs lock confirm format) #:transparent)
;; vault, lockfile, profile : string?; update matches outdated's inputs
;; because both answer from the same engine call, update-all: the vault
;; supplies the truth, the lockfile the claim, the profile the pins.
(struct command-update (vault lockfile profile format) #:transparent)
;; state  : string?  state directory update checks inside
;; profile, specs, state : string?; lock : (or/c string? #f)
;; D-041. activate needs the DECLARATION to learn each package's
;; relative install paths, and the STATE root to find where each package
;; was actually installed. Neither is derivable from the profile alone,
;; so both are named operands rather than hidden defaults: a profile is
;; a set of relative links and says nothing about where the store is.
;; `lock` is the same optional lockfile apply takes, and it becomes
;; provenance on the new generation.
(struct command-activate (profile specs state lock format) #:transparent)
;; profile, specs, state : string?; lock : (or/c string? #f)
(struct command-rollback (profile n format) #:transparent)
;; profile : string?  profile directory; n : string?  generation number
;; rollback needs no declaration: a generation already exists, so
;; repointing at one needs nothing but the profile and the number.
(struct command-remove (profile name specs state format) #:transparent)
;; profile, name, specs, state : string?  package to unlink
;; remove rebuilds the generation minus one package, so it needs the
;; same entries activate does: who is being removed, and what they
;; installed, so the surviving generation still accounts for every path.
(struct command-hold (profile name slot format) #:transparent)
;; profile name : string?; slot : string?  pinned version stream
;; D-026: `why` answers "why is this package here", and that answer is
;; only checkable if the two documents it consulted travel with it. So
;; both inputs are named operands, not hidden defaults: a lock and a
;; manifest and a name. One operand (the name alone) could not say
;; which lock it read, which makes the answer unreproducible.
(struct command-why (lockfile manifest name format) #:transparent)
;; lockfile, manifest : string?  the documents consulted
;; name : string?  package name to explain
(struct command-owner (profile rel format) #:transparent)
;; profile : string?  profile directory; rel : string?  relative path
;; vault, lockfile : string?; name : string?  the package to re-check.
;; The pin is deliberately NOT an operand: a caller-supplied pin would
;; let verify be asked to confirm something nobody ever claimed. Taking
;; the pin from the lockfile is what makes the check mean anything.
(struct command-verify (vault lockfile name format) #:transparent)
;; name   : string?  package name to re-check against its pin
(struct command-status (profile lockfile format) #:transparent)
;; profile : string?  profile directory; lockfile : string?  lock path
(struct command-held (profile format) #:transparent)
;; profile : string?  profile directory
(struct command-outdated (vault lockfile profile format) #:transparent)
;; vault : string?  vault dir; lockfile : string?  lock path;
;; profile : string?  profile directory for holds

;; any -> boolean, a parsed command value
(define (command? v)
  (or (command-check? v) (command-help? v)
      (command-plan? v) (command-lock? v) (command-fetch? v)
      (command-apply? v) (command-update? v) (command-activate? v)
      (command-rollback? v) (command-remove? v) (command-hold? v)
      (command-why? v) (command-owner? v) (command-verify? v)
      (command-status? v) (command-held? v) (command-outdated? v)))

;; ---------------------------------------------------------------------------
;; Parsing (one flag pass, then one command pass)

;; (listof string?) -> (values symbol? (listof string?)), --format in ONE
;; place (E-01). Default 'sexp; a missing value, a duplicate flag, or
;; anything but sexp|json raises kind 'config (exit 78, EX_CONFIG, via
;; pm-error-exit-code).
(define (parse-format args)
  (define (loop rest format seen?)
    (cond [(null? rest) (values format rest)]
          [(string=? (car rest) "--format")
           (when seen?
             (raise-pm-error 'config 'pm "duplicate --format flag"
                             #:fields `(("args" . ,(string-join args " ")))))
           (when (null? (cdr rest))
             (raise-pm-error 'config 'pm "--format needs sexp or json"
                             #:fields `(("args" . ,(string-join args " ")))))
           (define want (cadr rest))
           (unless (member want '("sexp" "json"))
             (raise-pm-error 'config 'pm "bad --format value"
                             #:fields `(("value" . ,want))
                             #:hint "--format takes sexp or json"))
           (loop (cddr rest) (string->symbol want) #t)]
          [else
           (define-values (fmt tail) (loop (cdr rest) format seen?))
           (values fmt (cons (car rest) tail))]))
  ;; loop above rebuilds the tail; re-run on the result would be quadratic
  ;; on huge argv, but argv is a handful of words, so clarity wins.
  (loop args 'sexp #f))

;; command table: name, operand count, maker over operand strings.
;; Makers use only car/cadr/caddr so no extra requires are needed.
(define command-table
  (list (list "plan" 1 (lambda (ops fmt) (command-plan (car ops) fmt)))
        (list "lock" 1 (lambda (ops fmt) (command-lock (car ops) fmt)))
        (list "fetch" 1 (lambda (ops fmt) (command-fetch (car ops) fmt)))
        (list "apply" 1 (lambda (ops fmt) (command-apply (car ops) #f #f fmt)))
        (list "update" 3
              (lambda (ops fmt)
                (command-update (car ops) (cadr ops) (caddr ops) fmt)))
        ;; activate is lifted out of this table by parse-args, which owns
        ;; its --lock flag exactly as it owns apply's; the entry stays so
        ;; `assoc` still finds the name and the arity error is ours.
        (list "activate" 3
              (lambda (ops fmt)
                (command-activate (car ops) (cadr ops) (caddr ops) #f fmt)))
        (list "rollback" 2
              (lambda (ops fmt)
                (command-rollback (car ops) (cadr ops) fmt)))
        (list "remove" 4
              (lambda (ops fmt)
                (command-remove (car ops) (cadr ops) (caddr ops)
                                (cadddr ops) fmt)))
        (list "hold" 3
              (lambda (ops fmt)
                (command-hold (car ops) (cadr ops) (caddr ops) fmt)))
        (list "why" 3
              (lambda (ops fmt)
                (command-why (car ops) (cadr ops) (caddr ops) fmt)))
        (list "owner" 2
              (lambda (ops fmt) (command-owner (car ops) (cadr ops) fmt)))
        (list "verify" 3
              (lambda (ops fmt)
                (command-verify (car ops) (cadr ops) (caddr ops) fmt)))
        (list "status" 2
              (lambda (ops fmt)
                (command-status (car ops) (cadr ops) fmt)))
        (list "held" 1 (lambda (ops fmt) (command-held (car ops) fmt)))
        (list "outdated" 3
              (lambda (ops fmt)
                (command-outdated (car ops) (cadr ops) (caddr ops) fmt)))))

;; (vectorof string) -> command
;; apply's own flags, lifted out before the fixed-arity table pass so
;; every OTHER command keeps its exact one-table arity rule. One walk
;; collects all three answers at once, so no flag is parsed twice and
;; none is silently dropped.
;;
;; --confirm takes no value: it is a gate you cross by NAMING it, never
;; by setting something. There is no env var and no third state, so
;; there is no way to apply without asking for it. D-040.
;; ONE flag parser for every command that takes --lock/--confirm.
;; apply and activate both need them, and two copies of a parser is how
;; the two drift apart: a duplicate --lock would be refused by one and
;; accepted by the other. `usage` is the caller's own invocation, so a
;; refusal quotes the command the user actually typed.
(define (parse-flag-args args usage)
  (define (loop rest ops lock confirm?)
    (cond
      [(null? rest) (values (reverse ops) lock confirm?)]
      [(string=? (car rest) "--confirm")
       (when confirm?
         (raise-pm-error 'config 'pm "duplicate --confirm flag"
                         #:fields `(("args" . ,(string-join args " ")))))
       (loop (cdr rest) ops lock #t)]
      [(string=? (car rest) "--lock")
       (when (null? (cdr rest))
         (raise-pm-error 'config 'pm "--lock needs a lockfile path"
                         #:fields `(("args" . ,(string-join args " ")))
                         #:hint usage))
       (when lock
         (raise-pm-error 'config 'pm "duplicate --lock flag"
                         #:fields `(("args" . ,(string-join args " ")))))
       (loop (cddr rest) ops (cadr rest) confirm?)]
      [else
       (loop (cdr rest) (cons (car rest) ops) lock confirm?)]))

  (loop args '() #f #f))

(define (parse-args argv)
  (define-values (format args) (parse-format (vector->list argv)))
  (cond [(null? args) (command-help)]
        [(and (= (length args) 1)
              (member (car args) '("--help" "-h")))
         (command-help)]
        [(and (= (length args) 2) (string=? (car args) "check"))
         (command-check (cadr args) format)]
        [(and (pair? args) (string=? (car args) "check"))
         (raise-pm-error 'config 'pm "check takes exactly one directory"
                         #:fields `(("args" . ,(string-join args " "))))]
        [(and (pair? args) (string=? (car args) "apply"))
         (define-values (ops lock confirm?)
           (parse-flag-args (cdr args) "pm apply <specs-dir> --lock LOCK"))
         (unless (= (length ops) 1)
           (raise-pm-error
            'config 'pm "apply takes exactly one specs directory"
            #:fields `(("args" . ,(string-join args " ")))
            #:hint "pm apply <specs-dir> [--lock FILE] [--confirm]"))
         (command-apply (car ops) lock confirm? format)]
        [(and (pair? args) (string=? (car args) "activate"))
         ;; activate takes the same flags as apply, so it uses the same
         ;; parser; the only difference is that it has no --confirm,
         ;; because profile-activate IS the act.
         (define-values (ops lock _confirm?)
           (parse-flag-args (cdr args)
                            "pm activate <profile> <specs-dir> <state> --lock LOCK"))
         (unless (= (length ops) 3)
           (raise-pm-error
            'config 'pm "activate takes a profile, a specs directory and a state root"
            #:fields `(("args" . ,(string-join args " ")))
            #:hint "pm activate <profile> <specs-dir> <state> [--lock FILE]"))
         (command-activate (car ops) (cadr ops) (caddr ops) lock format)]
        [(and (pair? args) (assoc (car args) command-table))
         (define entry (assoc (car args) command-table))
         (define want (cadr entry))
         (unless (= (length (cdr args)) want)
           (raise-pm-error
            'config 'pm
            (string-append (car args) " takes exactly "
                           (number->string want)
                           (if (= want 1) " operand" " operands"))
            #:fields `(("args" . ,(string-join args " ")))))
         ((caddr entry) (cdr args) format)]
        [(and (pair? args)
              (string-prefix? (car args) "--")
              (not (member (car args) '("--help" "-h"))))
         (raise-pm-error 'config 'pm "unknown flag"
                         #:fields `(("flag" . ,(car args)))
                         #:hint "try `pm --help`")]
        [else
         (raise-pm-error 'config 'pm "unknown command"
                         #:fields `(("args" . ,(string-join args " ")))
                         #:hint "try `pm --help`")]))

;; command -> list, name plus format plus operand strings, one arm
;; per command in struct order; unknown values fail closed, never silent
(define (command->datum cmd)
  (cond [(command-check? cmd)
         (list "check" (command-check-format cmd)
               (list (command-check-dir cmd)))]
        [(command-plan? cmd)
         (list "plan" (command-plan-format cmd)
               (list (command-plan-specs cmd)))]
        [(command-lock? cmd)
         (list "lock" (command-lock-format cmd)
               (list (command-lock-lockfile cmd)))]
        [(command-fetch? cmd)
         (list "fetch" (command-fetch-format cmd)
               (list (command-fetch-manifest cmd)))]
        [(command-apply? cmd)
         (list "apply" (command-apply-format cmd)
               (append (list (command-apply-specs cmd))
                       (if (command-apply-lock cmd)
                           (list (command-apply-lock cmd))
                           '())
                       (list (if (command-apply-confirm cmd) "yes" "no"))))]
        [(command-update? cmd)
         (list "update" (command-update-format cmd)
               (list (command-update-vault cmd)
                     (command-update-lockfile cmd)
                     (command-update-profile cmd)))]
        [(command-activate? cmd)
         (list "activate" (command-activate-format cmd)
               (append (list (command-activate-profile cmd)
                             (command-activate-specs cmd)
                             (command-activate-state cmd))
                       (if (command-activate-lock cmd)
                           (list (command-activate-lock cmd))
                           '())))]
        [(command-rollback? cmd)
         (list "rollback" (command-rollback-format cmd)
               (list (command-rollback-profile cmd)
                     (command-rollback-n cmd)))]
        [(command-remove? cmd)
         (list "remove" (command-remove-format cmd)
               (list (command-remove-profile cmd)
                     (command-remove-name cmd)
                     (command-remove-specs cmd)
                     (command-remove-state cmd)))]
        [(command-hold? cmd)
         (list "hold" (command-hold-format cmd)
               (list (command-hold-profile cmd)
                     (command-hold-name cmd)
                     (command-hold-slot cmd)))]
        [(command-why? cmd)
         (list "why" (command-why-format cmd)
               (list (command-why-lockfile cmd)
                     (command-why-manifest cmd)
                     (command-why-name cmd)))]
        [(command-owner? cmd)
         (list "owner" (command-owner-format cmd)
               (list (command-owner-profile cmd)
                     (command-owner-rel cmd)))]
        [(command-verify? cmd)
         (list "verify" (command-verify-format cmd)
               (list (command-verify-vault cmd)
                     (command-verify-lockfile cmd)
                     (command-verify-name cmd)))]
        [(command-status? cmd)
         (list "status" (command-status-format cmd)
               (list (command-status-profile cmd)
                     (command-status-lockfile cmd)))]
        [(command-held? cmd)
         (list "held" (command-held-format cmd)
               (list (command-held-profile cmd)))]
        [(command-outdated? cmd)
         (list "outdated" (command-outdated-format cmd)
               (list (command-outdated-vault cmd)
                     (command-outdated-lockfile cmd)
                     (command-outdated-profile cmd)))]
        [(command-help? cmd) (list "help" 'sexp '())]
        [else (raise-pm-error 'internal 'pm "not a command"
                              #:fields `(("value" . ,(format "~s" cmd))))]))

;; command -> string, stable sexp shape for goldens
(define (command->sexp cmd)
  (format "~s" (command->datum cmd)))

;; command -> string, the envelope WITHOUT its closing brace: a
;; command with result keys appends ",\"key\":..." then closes it.
(define (command-envelope cmd)
  (define d (command->datum cmd))
  (string-append "{\"name\":" (format "~s" (car d))
                 ",\"format\":" (format "~s" (symbol->string (cadr d)))
                 ",\"operands\":["
                 (string-join (map (lambda (o) (format "~s" o)) (caddr d))
                              ", ")
                 "]"))

;; command -> string, fixed key order until E-26 hardens the schema.
;; Operands render through~s, which matches JSON for the ASCII paths
;; and names commands take today.
(define (command->json cmd)
  (string-append (command-envelope cmd) "}"))


;; ---------------------------------------------------------------------------
;; Checking (one clean line per good spec, every error shown)

;; path-string -> exit code, validates every .rktd, 0 or 3
(define (run-check dir)
  (require-dir dir)
  (with-op 'check (dir-text dir) "every .rktd in the directory was validated"
           #:how "read each spec; a bad one is reported and counted"
           (lambda ()
             (define failures
               (for/fold ([bad 0]) ([f (in-list (sorted-rktd-files dir))])
                 (with-handlers
                     ([exn:fail:pm?
                       (lambda (e)
                         ;; The reason a spec was NOT accepted, in
                         ;; the feed as well as on the screen.
                         (skip 'check
                               (path->string f)
                               (string-append "rejected: "
                                              (exn-message e)))
                         (display-pm-error e)
                         (+ bad 1))])
                   (define s (read-spec-file f))
                   (step 'check
                         (string-append (symbol->string (spec-name s))
                                        " "
                                        (version->string (spec-version s)))
                         "the spec parsed and passed every field check"
                         #:how (path->string f))
                   (display-result
                    (list (format "ok: ~a ~a"
                                  (spec-name s)
                                  (version->string (spec-version s)))))
                   bad)))
             (if (zero? failures) 0 3))))

;; ---------------------------------------------------------------------------
;; ---------------------------------------------------------------------------
;; THE ENTRIES BUILDER.
;;
;; profile-activate and profile-remove both take a list of
;;   (name source rels)
;; where rels are the RELATIVE paths a package installed. Until this
;; function existed, nothing in production built that list: it appeared
;; only as hand-written literals in two tests. Every profile command
;; therefore starts here, and there is one definition, not three.
;;
;; Why a lockfile alone cannot do this: a lock-entry is
;; (name version commit url slot flags spec-hash input-hash deps) and
;; carries NO relative paths. Those live in the spec's install form. So
;; the walk here is spec-install-dests -- the SAME walk
;; check-spec-conflicts and spec-install-dests already use -- rather
;; than a second one written to agree with it later.
;;
;; The install directory is the store path apply writes to:
;; <state>/store/<name>/<slot>/<version>-<hash12>/, which is exactly
;; package-plan-store-dir under "store". Deriving it any other way would
;; let activate disagree with apply about where a package lives.
;;
;; specs-dir : string?  the declaration to read
;; state-dir : string?  the state root holding the store
;; -> (listof (list name:string? source:path-string? rels:(listof string?)))

(define (profile-entries specs-dir state-dir)
  ;; preflight off: these packages are already installed, so there is
  ;; nothing to resolve against the vault yet, and refusing on a missing
  ;; source would be wrong here.
  (define specs (wait-for 'activate "read-declaration"
                          "no package's install paths are known until its spec is read"
                          #:how (format "read every spec under ~a" specs-dir)
                          (lambda ()
                            ;; the vault argument must still be a real
                            ;; path-string: scan-specs' contract rejects
                            ;; "", and with preflight off it is never read
                            ;; anyway. state-dir is the honest stand-in.
                            (scan-specs specs-dir state-dir #:preflight #f))))
  (define by-name
    (for/hash ([s (in-list specs)])
      (values (symbol->string (spec-name s)) s)))
  (define plans
    (wait-for 'activate "derive-plans"
              "the store path of a package is its resolved plan's, not its spec's"
              #:how (format "derive ~a package(s) in resolve order" (length specs))
              (lambda ()
                (derive-plans specs '() '()))))
  (for/list ([pp (in-list plans)])
    (define name (symbol->string (package-plan-name pp)))
    (define spec (hash-ref by-name name))
    (list name
          (path->string
           (build-path state-dir "store" (package-plan-store-dir pp)))
          (spec-install-dests spec))))

;; command -> string, the exact --format json document: the envelope
;; from command->json, then the command's result keys. A STRING, not a
;; jsexpr: the envelope order is documented and must not be left to
;; the hash printer.
(define (command-json cmd)
  (define envelope (command-envelope cmd))
  (cond
    [(command-plan? cmd)
     (string-append envelope
                    ",\"packages\":"
                    (json-text (plan-document (command-plan-specs cmd)))
                    "}")]
    [(command-check? cmd)
     (string-append envelope
                    ",\"ok\":"
                    (json-text (check-ok-lines (command-check-dir cmd)))
                    "}")]
    [(command-status? cmd)
     (string-append envelope
                    ",\"packages\":"
                    (json-text (status-document (command-status-profile cmd)
                                               (command-status-lockfile cmd)))
                    "}")]
    [(command-held? cmd)
     (string-append envelope
                    ",\"holds\":"
                    (json-text (held-document (command-held-profile cmd)))
                    "}")]
    [(command-outdated? cmd)
     (string-append envelope
                    ",\"report\":"
                    (json-text (outdated-document (command-outdated-vault cmd)
                                                 (command-outdated-lockfile cmd)
                                                 (command-outdated-profile cmd)))
                    "}")]
    [(command-fetch? cmd)
     (string-append envelope
                    ",\"results\":"
                    (json-text (fetch-document (command-fetch-manifest cmd)))
                    "}")]
    [(command-help? cmd) (string-append envelope "}")]
    [(command-apply? cmd)
     (string-append
      envelope
      ",\"confirmed\":"
      (json-text (if (command-apply-confirm cmd) #t #f))
      ",\"applied\":"
      (json-text (if (command-apply-confirm cmd) #t #f))
      ",\"results\":"
      (json-text (apply-document (command-apply-specs cmd)
                                 (command-apply-lock cmd)))
      "}")]
    [(command-lock? cmd)
     (string-append envelope
                    ",\"lock\":"
                    (json-text (lock-document (command-lock-lockfile cmd)))
                    "}")]
    [(command-why? cmd)
     (string-append
      envelope
      ",\"why\":"
      (json-text (why-document (command-why-lockfile cmd)
                              (command-why-manifest cmd)
                              (command-why-name cmd)))
      "}")]
    [(command-owner? cmd)
     (string-append
      envelope
      ",\"owner\":"
      (json-text (owner-document (command-owner-profile cmd)
                                 (command-owner-rel cmd)))
      "}")]
    [(command-update? cmd)
     (string-append
      envelope
      ",\"report\":"
      (json-text (outdated-document (command-update-vault cmd)
                                   (command-update-lockfile cmd)
                                   (command-update-profile cmd)))
      "}")]
    [(command-verify? cmd)
     (string-append
      envelope
      ",\"verify\":"
      (json-text (verify-document (command-verify-vault cmd)
                                  (command-verify-lockfile cmd)
                                  (command-verify-name cmd)))
      "}")]
    [(command-hold? cmd)
     (string-append
      envelope
      ",\"pinned\":"
      (json-text (hasheq 'profile (command-hold-profile cmd)
                         'name (command-hold-name cmd)
                         'slot (command-hold-slot cmd)))
      "}")]
    [(command-rollback? cmd)
     (string-append
      envelope
      ",\"generation\":"
      (json-text
       (generation-document
        (rollback-generation (command-rollback-profile cmd)
                             (command-rollback-n cmd))))
      "}")]
    [(command-activate? cmd)
     (string-append
      envelope
      ",\"activated\":"
      (json-text
       (activate-document
        (command-activate-specs cmd)
        (command-activate-state cmd)
        (command-activate-lock cmd)
        (profile-activate
         (profile-entries (command-activate-specs cmd)
                          (command-activate-state cmd))
         (command-activate-profile cmd)
         #:interface (command-activate-profile cmd)
         #:specs (command-activate-specs cmd)
         #:lock (command-activate-lock cmd))))
      "}")]
    [(command-remove? cmd)
     (string-append
      envelope
      ",\"generation\":"
      (json-text
       (generation-document
        (profile-remove
         (command-remove-profile cmd)
         (command-remove-name cmd)
         (profile-entries (command-remove-specs cmd)
                          (command-remove-state cmd)))))
      "}")]
    [else
     (raise-pm-error 'config 'pm "command not executable yet"
                     #:fields `(("command" . ,(car (command->datum cmd)))))]))


;; ---------------------------------------------------------------------------
;; run-cli -- the executable entry, moved whole from cli.rkt's module+
;; main (step 8): argv in, exit code out. The run opens before parsing
;; (D-036) and closes on every path; the handlers turn each failure
;; into its exit code.
(define (run-cli [raw-args (current-command-line-arguments)])
  (define-values (cancel-evt trigger-cancel!) (make-cancel-source))
  ;; D-036: every pm invocation is a run. Opening it here is what makes
  ;; the feed real for every command at once: without this, nothing
  ;; downstream has a file to write to and nothing can be silent.
  (void (begin-run! #:who 'pm))
  (define code
    (with-handlers ([exn:break? (lambda (_) (trigger-cancel!) 130)]
                    [exn:fail:pm?
                     (lambda (e)
                       (display-pm-error e)
                       (pm-error-exit-code e))]
                    [exn:fail?
                     (lambda (e)
                       (display-internal-error e)
                       70)])
      (define cmd (parse-args raw-args))
      (with-op 'cli "pm" "a command was requested"
               #:how (string-join (vector->list raw-args) " ")
               #:inputs (vector->list raw-args)
               (lambda () 0))
      (cond [(command-help? cmd) (display-help) 0]
            [(command-check? cmd)
             (run-check (command-check-dir cmd))]
            [(command-fetch? cmd)
             (if (eq? 'json (command-fetch-format cmd))
                 (begin (display-result (list (command-json cmd))) 0)
                 (begin
                   (display-result
                    (update-report
                     (pm-fetch (path->string (default-vault-dir))
                               (command-fetch-manifest cmd))))
                   0))]
            [(command-plan? cmd)
             (if (eq? 'json (command-plan-format cmd))
                 (begin (display-result (list (command-json cmd))) 0)
                 (begin
                   (for ([p (in-list (plan-document
                                      (command-plan-specs cmd)))])
                     (display-result (list (format "~a" p))))
                   0))]
            [(command-status? cmd)
             (if (eq? 'json (command-status-format cmd))
                 (begin (display-result (list (command-json cmd))) 0)
                 (begin
                   (for ([p (in-list (status-document
                                      (command-status-profile cmd)
                                      (command-status-lockfile cmd)))])
                     (display-result
                      (list (format "~a ~a [~a]~a" (hash-ref p 'name)
                                    (hash-ref p 'version)
                                    (hash-ref p 'slot)
                                    (if (hash-ref p 'held) " held" "")))))
                   0))]
            [(command-held? cmd)
             (if (eq? 'json (command-held-format cmd))
                 (begin (display-result (list (command-json cmd))) 0)
                 (begin
                   (for ([h (in-list (held-document
                                      (command-held-profile cmd)))])
                     (display-result
                      (list (format "~a ~a" (hash-ref h 'name)
                                    (hash-ref h 'slot)))))
                   0))]
            [(command-hold? cmd)
             ;; hold pins a slot. The pin is the whole action; there is
             ;; no dry run to offer, because nothing is fetched or
             ;; built — it records an intent that later updates honour.
             (profile-hold (command-hold-profile cmd)
                           (command-hold-name cmd)
                           (command-hold-slot cmd))
             (if (eq? 'json (command-hold-format cmd))
                 (begin (display-result (list (command-json cmd))) 0)
                 (begin
                   (display-result
                    (list (format "pinned ~a [~a] in ~a"
                                  (command-hold-name cmd)
                                  (command-hold-slot cmd)
                                  (command-hold-profile cmd))))
                   0))]
            [(command-verify? cmd)
             (let ([v (verify-document (command-verify-vault cmd)
                                       (command-verify-lockfile cmd)
                                       (command-verify-name cmd))])
               (if (eq? 'json (command-verify-format cmd))
                   (begin (display-result (list (command-json cmd))) 0)
                   (begin
                     (display-result (list (verify->text
                                            (list (hash-ref v 'verdict)
                                                  (hash-ref v 'ok)
                                                  (hash-ref v 'detail)))))
                     0)))]
            [(command-update? cmd)
             (if (eq? 'json (command-update-format cmd))
                 (begin (display-result (list (command-json cmd))) 0)
                 (begin
                   (for ([r (in-list
                             (outdated-document (command-update-vault cmd)
                                                (command-update-lockfile cmd)
                                                (command-update-profile cmd)))])
                     (display-result (list (format "~a" r))))
                   0))]
            [(command-lock? cmd)
             (if (eq? 'json (command-lock-format cmd))
                 (begin (display-result (list (command-json cmd))) 0)
                 (begin
                   (for ([e (in-list (lockfile-entries
                                      (read-lockfile
                                       (command-lock-lockfile cmd))))])
                     (display-result
                      (list (format "~a ~a [~a] ~a"
                                    (lock-entry-name e)
                                    (lock-entry-version e)
                                    (lock-entry-slot e)
                                    (lock-entry-commit e)))))
                   0))]
            [(command-why? cmd)
             (let ([w (why-document (command-why-lockfile cmd)
                                   (command-why-manifest cmd)
                                   (command-why-name cmd))])
               (if (eq? 'json (command-why-format cmd))
                   (begin (display-result (list (command-json cmd))) 0)
                   (begin (display-result (list (why->text
                                                (list (hash-ref w 'verdict)
                                                      (hash-ref w 'declared-by)
                                                      (hash-ref w 'version)
                                                      (hash-ref w 'files)
                                                      (hash-ref w 'run)
                                                      (hash-ref w 'why)))))
                          0)))]
            [(command-owner? cmd)
             (if (eq? 'json (command-owner-format cmd))
                 (begin (display-result (list (command-json cmd))) 0)
                 (begin
                   (display-result
                    (list (owner->text
                           (query-owner (command-owner-profile cmd)
                                        (command-owner-rel cmd)))))
                   0))]
            [(command-apply? cmd)
             (if (command-apply-confirm cmd)
                 (let ([rows (pm-apply (command-apply-specs cmd)
                                       #:lock (command-apply-lock cmd)
                                       #:cancel cancel-evt)])
                   (if (eq? 'json (command-apply-format cmd))
                       (begin (display-result (list (command-json cmd))) 0)
                       (begin
                         (display-result
                          (list (format "applied ~a package(s) from ~a"
                                        (length rows)
                                        (command-apply-specs cmd))))
                         0)))
                 ;; no --confirm: derive the plan, show it, change nothing,
                 ;; exit 0. A preview is the ordinary answer, not a lesser
                 ;; one, so this is not an error path.
                 (let ([rows (apply-document (command-apply-specs cmd)
                                             (command-apply-lock cmd))])
                   (if (eq? 'json (command-apply-format cmd))
                       (begin (display-result (list (command-json cmd))) 0)
                       (begin
                         (display-result
                          (apply-preview (command-apply-specs cmd) rows))
                         0))))]
            [(command-outdated? cmd)
             (if (eq? 'json (command-outdated-format cmd))
                 (begin (display-result (list (command-json cmd))) 0)
                 (begin
                   (display-result
                    (outdated-document (command-outdated-vault cmd)
                                       (command-outdated-lockfile cmd)
                                       (command-outdated-profile cmd)))
                   0))]
            [(command-rollback? cmd)
             (let ([gen (rollback-generation (command-rollback-profile cmd)
                                             (command-rollback-n cmd))])
               (if (eq? 'json (command-rollback-format cmd))
                   (begin (display-result (list (command-json cmd))) 0)
                   (begin
                     (display-result
                      (list (format "profile now points at ~a"
                                    (path->string gen))))
                     0)))]
            [(command-activate? cmd)
             (let ([gen (profile-activate
                         (profile-entries (command-activate-specs cmd)
                                          (command-activate-state cmd))
                         (command-activate-profile cmd)
                         #:interface (command-activate-profile cmd)
                         #:specs (command-activate-specs cmd)
                         #:lock (command-activate-lock cmd))])
               (if (eq? 'json (command-activate-format cmd))
                   (begin (display-result (list (command-json cmd))) 0)
                   (begin
                     (display-result
                      (list (format "activated; profile now points at ~a"
                                    (path->string gen))))
                     0)))]
            [(command-remove? cmd)
             (let ([gen (profile-remove
                         (command-remove-profile cmd)
                         (command-remove-name cmd)
                         (profile-entries (command-remove-specs cmd)
                                          (command-remove-state cmd)))])
               (if (eq? 'json (command-remove-format cmd))
                   (begin (display-result (list (command-json cmd))) 0)
                   (begin
                     (display-result
                      (list (format "removed ~a; profile now points at ~a"
                                    (command-remove-name cmd)
                                    (path->string gen))))
                     0)))]
            [else
             (raise-pm-error 'config 'pm "command not executable yet"
                             #:fields `(("command" . ,(car (command->datum cmd)))))])))
  ;; The run closes on every path, including the failing ones: the FAIL
  ;; event is already in the feed, and end-run! only adds the closure.
  (with-handlers ([(lambda (e) #t) (lambda (e) (void))])
    (end-run! (format "exit=~a" code)))
  code)
