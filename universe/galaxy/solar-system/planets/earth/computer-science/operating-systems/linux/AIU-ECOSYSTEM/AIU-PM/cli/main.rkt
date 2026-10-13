#lang racket/base
;; main.rkt -- the pm command line: one command per stage, each with
;; --format sexp|json. Thin over the core verbs; every failure becomes
;; an exit code here (E-5 narrow handlers, E-15 codes). Parsing plus
;; command rendering land here (E-18a); execution wiring arrives per
;; command after that, and unwired commands refuse loudly at dispatch.

(require racket/contract/base
         racket/file
         racket/list
         racket/port
         racket/string
         json
         "../core/cancel.rkt"
         "../core/errors.rkt"
         "../core/spec.rkt"
         "../core/spec-read.rkt"
         "../core/ui.rkt"
         "../core/verbose.rkt"
         "../core/version.rkt"
         "../core/lock.rkt"
         "../backends/query.rkt"
         "../backends/update.rkt")

(provide
 (struct-out command-check)
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
 (contract-out
  ;; any -> boolean, a parsed command value
  [command? (-> any/c boolean?)]
  ;; (vectorof string) -> command, bad usage raises kind 'config
  [parse-args (-> (vectorof string?) command?)]
  ;; command -> string, stable sexp shape for goldens
  [command->sexp (-> command? string?)]
  ;; command -> string, fixed key order until E-26 hardens the schema
  [command->json (-> command? string?)]
  ;; path-string -> exit code, validates every .rktd, 0 or 3
  [run-check (-> path-string? exact-nonnegative-integer?)]
  ;; command -> string, the exact --format json document: the envelope
  ;; from command->json plus that command's result keys. Raises kind
  ;; 'config for a command that is not executable yet (E-18 debt).
  [run-command-json (-> command? string?)]
  ;; jsexpr -> string, the value as JSON text (write-json alone
  ;; prints and returns void)
  [json-text (-> jsexpr? string?)]
  ;; -> void, prints usage to stdout
  [display-help (-> void?)]))

;; ---------------------------------------------------------------------------
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
(struct command-apply (state format) #:transparent)
;; state  : string?  state directory the plan applies inside
(struct command-update (state format) #:transparent)
;; state  : string?  state directory update checks inside
(struct command-activate (profile format) #:transparent)
;; profile : string?  profile directory to flip
(struct command-rollback (profile n format) #:transparent)
;; profile : string?  profile directory; n : string?  generation number
(struct command-remove (profile name format) #:transparent)
;; profile : string?  profile directory; name : string?  package name
(struct command-hold (profile name slot format) #:transparent)
;; profile name : string?; slot : string?  pinned version stream
(struct command-why (name format) #:transparent)
;; name   : string?  package name to explain
(struct command-owner (profile rel format) #:transparent)
;; profile : string?  profile directory; rel : string?  relative path
(struct command-verify (name format) #:transparent)
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
;; anything but sexp|json raises kind 'config (exit 2 via pm-error-exit-code).
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
        (list "apply" 1 (lambda (ops fmt) (command-apply (car ops) fmt)))
        (list "update" 1 (lambda (ops fmt) (command-update (car ops) fmt)))
        (list "activate" 1
              (lambda (ops fmt) (command-activate (car ops) fmt)))
        (list "rollback" 2
              (lambda (ops fmt)
                (command-rollback (car ops) (cadr ops) fmt)))
        (list "remove" 2
              (lambda (ops fmt) (command-remove (car ops) (cadr ops) fmt)))
        (list "hold" 3
              (lambda (ops fmt)
                (command-hold (car ops) (cadr ops) (caddr ops) fmt)))
        (list "why" 1 (lambda (ops fmt) (command-why (car ops) fmt)))
        (list "owner" 2
              (lambda (ops fmt) (command-owner (car ops) (cadr ops) fmt)))
        (list "verify" 1 (lambda (ops fmt) (command-verify (car ops) fmt)))
        (list "status" 2
              (lambda (ops fmt)
                (command-status (car ops) (cadr ops) fmt)))
        (list "held" 1 (lambda (ops fmt) (command-held (car ops) fmt)))
        (list "outdated" 3
              (lambda (ops fmt)
                (command-outdated (car ops) (cadr ops) (caddr ops) fmt)))))

;; (vectorof string) -> command
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
               (list (command-apply-state cmd)))]
        [(command-update? cmd)
         (list "update" (command-update-format cmd)
               (list (command-update-state cmd)))]
        [(command-activate? cmd)
         (list "activate" (command-activate-format cmd)
               (list (command-activate-profile cmd)))]
        [(command-rollback? cmd)
         (list "rollback" (command-rollback-format cmd)
               (list (command-rollback-profile cmd)
                     (command-rollback-n cmd)))]
        [(command-remove? cmd)
         (list "remove" (command-remove-format cmd)
               (list (command-remove-profile cmd)
                     (command-remove-name cmd)))]
        [(command-hold? cmd)
         (list "hold" (command-hold-format cmd)
               (list (command-hold-profile cmd)
                     (command-hold-name cmd)
                     (command-hold-slot cmd)))]
        [(command-why? cmd)
         (list "why" (command-why-format cmd)
               (list (command-why-name cmd)))]
        [(command-owner? cmd)
         (list "owner" (command-owner-format cmd)
               (list (command-owner-profile cmd)
                     (command-owner-rel cmd)))]
        [(command-verify? cmd)
         (list "verify" (command-verify-format cmd)
               (list (command-verify-name cmd)))]
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

;; -> void, prints usage to stdout
(define (display-help)
  ;; V-3: the usage text is printed ONCE, through display-result, so
  ;; no command in the tree prints by itself.
  (display-result
   (list
    "usage: pm [--format sexp|json] COMMAND [ARGS] | pm --help"
    ""
    "  check DIR          validate every .rktd file, print ok lines"
    "  plan SPECDIR       show the install plan (not executable yet)"
    "  lock LOCKFILE      show the lockfile plan (not executable yet)"
    "  fetch MANIFEST     fetch all declared packages (not yet)"
    "  apply STATEDIR     apply a plan (not executable yet)"
    "  update STATEDIR    check all packages (not executable yet)"
    "  activate PROFILE   flip the profile (not executable yet)"
    "  rollback PROFILE N repoint at generation N (not yet)"
    "  remove PROFILE PKG unlink a package (not executable yet)"
    "  hold PROFILE PKG SLOT pin a slot (not executable yet)"
    "  why NAME           explain a package (not executable yet)"
    "  owner PROFILE REL  who owns a path (not executable yet)"
    "  verify NAME        re-check a tree (not executable yet)"
    "  status PROFILE LOCKFILE what is installed, with held marks"
    "  held PROFILE       what is held"
    "  outdated VAULT LOCKFILE PROFILE what is behind, from the vault"
    "  --format           output shape, sexp (default) or json"
   )))

;; ---------------------------------------------------------------------------
;; Checking (one clean line per good spec, every error shown)

;; path-string path -> boolean, regular file ending .rktd
(define (rktd-file? dir p)
  (define full (build-path dir p))
  (and (file-exists? full)
       (string-suffix? (path->string p) ".rktd")))

;; path-string -> (listof path), sorted .rktd files directly inside
(define (sorted-rktd-files dir)
  (map string->path
       (sort (for/list ([p (in-list (directory-list dir))]
                        #:when (rktd-file? dir p))
               (path->string (build-path dir p)))
             string<?)))

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
;; Result documents (E-26). The envelope is name/format/operands; a
;; command that produces something adds result keys. Key order in
;; write-json follows hash insertion order, so the tests and the
;; examples in docs/API.org agree on it.

;; path-string -> void, kind 'config when the directory is missing
(define (require-dir dir)
  (unless (directory-exists? dir)
    (raise-pm-error 'config 'pm "directory not found"
                    #:fields `(("dir" . ,dir)))))

;; any -> string, a directory as text for an event. The CLI hands these
;; functions strings (they come from argv) and the tests hand them
;; paths, so both shapes must narrate.
(define (dir-text d)
  (if (path? d) (path->string d) (format "~a" d)))

;; path-string -> jsexpr (listof jsexpr), one object per .rktd in DIR,
;; in file order. Reads every spec, so a bad spec raises here exactly
;; as it does in run-check. No resolution, no ordering: the plan as
;; written. Keys inside a package are alphabetical, which is what
;; write-json does to an immutable hash; the envelope order is ours.
(define (plan-document dir)
  (require-dir dir)
  (with-op 'plan (dir-text dir) "an install plan was requested"
           #:how "read every .rktd in the directory"
           (lambda ()
             (for/list ([f (in-list (sorted-rktd-files dir))])
               (define s (read-spec-file f))
               (step 'plan
                     (string-append (symbol->string (spec-name s))
                                    " "
                                    (version->string (spec-version s)))
                     "every spec in the directory enters the plan"
                     #:how (path->string f))
               (hasheq 'name (symbol->string (spec-name s))
                       'version (version->string (spec-version s))
                       'deps (for/list ([d (in-list (spec-deps s))])
                               (hasheq 'name (symbol->string (dep-name d))
                                       'version (version->string
                                                 (dep-version d)))))))))

;; path-string -> (listof string), the ok lines of a check run
(define (check-ok-lines dir)
  (require-dir dir)
  (with-op 'check (dir-text dir) "every .rktd in the directory was validated"
           #:how "read each spec; a bad one raises kind 'spec"
           (lambda ()
             (for/list ([f (in-list (sorted-rktd-files dir))])
               (define s (read-spec-file f))
               (step 'check
                     (string-append (symbol->string (spec-name s))
                                    " "
                                    (version->string (spec-version s)))
                     "the spec parsed and passed every field check"
                     #:how (path->string f))
               (format "ok: ~a ~a"
                       (spec-name s)
                       (version->string (spec-version s)))))))

;; path-string path-string -> jsexpr, one object per installed
;; package, in name order. Reads the lock for versions and slots; the
;; ledger underneath answers what is really there.
(define (status-document profile lockfile)
  (define locks (lockfile-entries (read-lockfile lockfile)))
  (define rows (query-status profile locks))
  (for/list ([r (in-list rows)])
    (hasheq 'name (first r)
            'version (second r)
            'slot (third r)
            'held (if (fourth r) #t #f)
            'rels (fifth r))))

;; path-string -> jsexpr, the holds as pairs
(define (held-document profile)
  (define holds (query-held profile))
  (for/list ([h (in-list holds)])
    (hasheq 'name (first h) 'slot (second h))))

;; path-string path-string path-string -> (listof string), one info line
;; per locked package, input order kept. Outdated is answered by the
;; vault, not by the lock alone.
(define (outdated-document vault lockfile profile)
  (define locks (lockfile-entries (read-lockfile lockfile)))
  (update-report (update-all vault locks '() profile)))

;; jsexpr -> string, write-json prints to the current port and returns
;; void; here the value is spliced into a bigger document.
(define (json-text j)
  (with-output-to-string (lambda () (write-json j))))

;; command -> string, the exact --format json document: the envelope
;; from command->json, then the command's result keys. A STRING, not a
;; jsexpr: the envelope order is documented and must not be left to
;; the hash printer.
(define (run-command-json cmd)
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
    [(command-help? cmd) (string-append envelope "}")]
    [else
     (raise-pm-error 'config 'pm "command not executable yet"
                     #:fields `(("command" . ,(car (command->datum cmd)))))]))

;; ---------------------------------------------------------------------------
(module+ main
  (define-values (cancel-evt trigger-cancel!) (make-cancel-source))
  ;; D-036: every pm invocation is a run. Opening it here is what makes
  ;; the feed real for every command at once: without this, nothing
  ;; downstream has a file to write to and nothing can be silent.
  (define raw-args (current-command-line-arguments))
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
            [(command-plan? cmd)
             (if (eq? 'json (command-plan-format cmd))
                 (begin (display-result (list (run-command-json cmd))) 0)
                 (begin
                   (for ([p (in-list (plan-document
                                      (command-plan-specs cmd)))])
                     (display-result (list (format "~a" p))))
                   0))]
            [(command-status? cmd)
             (if (eq? 'json (command-status-format cmd))
                 (begin (display-result (list (run-command-json cmd))) 0)
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
                 (begin (display-result (list (run-command-json cmd))) 0)
                 (begin
                   (for ([h (in-list (held-document
                                      (command-held-profile cmd)))])
                     (display-result
                      (list (format "~a ~a" (hash-ref h 'name)
                                    (hash-ref h 'slot)))))
                   0))]
            [(command-outdated? cmd)
             (if (eq? 'json (command-outdated-format cmd))
                 (begin (display-result (list (run-command-json cmd))) 0)
                 (begin
                   (display-result
                    (outdated-document (command-outdated-vault cmd)
                                       (command-outdated-lockfile cmd)
                                       (command-outdated-profile cmd)))
                   0))]
            [else
             (raise-pm-error 'config 'pm "command not executable yet"
                             #:fields `(("command" . ,(car (command->datum cmd)))))])))
  ;; The run closes on every path, including the failing ones: the FAIL
  ;; event is already in the feed, and end-run! only adds the closure.
  (with-handlers ([(lambda (e) #t) (lambda (e) (void))])
    (end-run! (format "exit=~a" code)))
  (exit code))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/list
           racket/runtime-path
           racket/string
           json
           "../core/errors.rkt")

  ;; Parsing: empty and flags mean help; check takes one directory.
  (check-pred command-help? (parse-args #()))
  (check-pred command-help? (parse-args #("--help")))
  (check-pred command-help? (parse-args #("-h")))
  (check-equal? (command-check-dir (parse-args #("check" "specs/")))
                "specs/")
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("check"))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("frobnicate"))
                'no-error))
  ;; --format is parsed in one place, default sexp, before or after.
  (check-eq? (command-check-format (parse-args #("check" "specs/")))
             'sexp)
  (check-eq? (command-check-format
              (parse-args #("check" "specs/" "--format" "json")))
             'json)
  (check-eq? (command-check-format
              (parse-args #("--format" "json" "check" "specs/")))
             'json)
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("check" "specs/" "--format" "yaml"))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("check" "specs/" "--format"))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("--format" "sexp" "--format" "json"
                               "check" "specs/"))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("--bogus"))
                'no-error))
  (check-exn exn:fail:contract?
             (lambda () (parse-args '("check" "x"))))

  ;; Checking: a good file prints ok and exits 0.
  (define check-dir (make-temporary-directory "pm-cli~a"))
  (call-with-output-file (build-path check-dir "good.rktd")
    (lambda (port)
      (displayln "(spec (format-version 2) (name demo) (version \"1.0\")" port)
      (displayln "  (summary \"s\")" port)
      (displayln "  (source (git \"https://example.org/d.git\"" port)
      (displayln "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))" port)
      (displayln "  (build (steps (copy \"a\" \"b\")))" port)
      (displayln "  (install (prefix (bin \"b\")))" port)
      (displayln "  (license mit) (homepage \"https://example.org\"))" port)))
  (define check-out (open-output-string))
  (check-equal? (parameterize ([current-output-port check-out])
                  (run-check check-dir))
                0)
  (check-regexp-match #rx"ok: demo 1.0" (get-output-string check-out))

  ;; A bad file prints its error and exits 3; others still checked.
  (call-with-output-file (build-path check-dir "bad.rktd")
    (lambda (port)
      (displayln "(spec (format-version 2) (bogus 1))" port)))
  (define bad-err (open-output-string))
  (define bad-out (open-output-string))
  (check-equal? (parameterize ([current-output-port bad-out]
                               [current-error-port bad-err])
                  (run-check check-dir))
                3)
  (check-regexp-match #rx"unknown key" (get-output-string bad-err))
  (check-regexp-match #rx"ok: demo 1.0" (get-output-string bad-out))

  ;; Missing directories fail at the boundary, kind 'config.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (run-check (build-path check-dir "no-such-dir"))
                'no-error))

  ;; Empty directories pass vacuously.
  (define empty-dir (build-path check-dir "empty"))
  (make-directory empty-dir)
  (check-equal? (run-check empty-dir) 0)

  ;; E-18a: every stage parses; one golden per command per format.
  (define (check-command pred argv sexp json)
    (define cmd (parse-args argv))
    (check-pred pred cmd)
    (check-equal? (command->sexp cmd) sexp)
    (check-equal? (command->json cmd) json))
  (check-command command-plan? #("plan" "specs/")
                 "(\"plan\" sexp (\"specs/\"))"
                 "{\"name\":\"plan\",\"format\":\"sexp\",\"operands\":[\"specs/\"]}")
  (check-command command-lock? #("lock" "pm.lock")
                 "(\"lock\" sexp (\"pm.lock\"))"
                 "{\"name\":\"lock\",\"format\":\"sexp\",\"operands\":[\"pm.lock\"]}")
  (check-command command-fetch? #("fetch" "manifest.rktd")
                 "(\"fetch\" sexp (\"manifest.rktd\"))"
                 "{\"name\":\"fetch\",\"format\":\"sexp\",\"operands\":[\"manifest.rktd\"]}")
  (check-command command-apply? #("apply" "state")
                 "(\"apply\" sexp (\"state\"))"
                 "{\"name\":\"apply\",\"format\":\"sexp\",\"operands\":[\"state\"]}")
  (check-command command-update? #("update" "state")
                 "(\"update\" sexp (\"state\"))"
                 "{\"name\":\"update\",\"format\":\"sexp\",\"operands\":[\"state\"]}")
  (check-command command-activate? #("activate" "profile")
                 "(\"activate\" sexp (\"profile\"))"
                 "{\"name\":\"activate\",\"format\":\"sexp\",\"operands\":[\"profile\"]}")
  (check-command command-rollback? #("rollback" "profile" "3")
                 "(\"rollback\" sexp (\"profile\" \"3\"))"
                 "{\"name\":\"rollback\",\"format\":\"sexp\",\"operands\":[\"profile\", \"3\"]}")
  (check-command command-remove? #("remove" "profile" "pkg-a")
                 "(\"remove\" sexp (\"profile\" \"pkg-a\"))"
                 "{\"name\":\"remove\",\"format\":\"sexp\",\"operands\":[\"profile\", \"pkg-a\"]}")
  (check-command command-hold? #("hold" "profile" "pkg-a" "default")
                 "(\"hold\" sexp (\"profile\" \"pkg-a\" \"default\"))"
                 (string-append "{\"name\":\"hold\",\"format\":\"sexp\","
                                "\"operands\":[\"profile\", \"pkg-a\", \"default\"]}"))
  (check-command command-why? #("why" "pkg-a")
                 "(\"why\" sexp (\"pkg-a\"))"
                 "{\"name\":\"why\",\"format\":\"sexp\",\"operands\":[\"pkg-a\"]}")
  (check-command command-owner? #("owner" "profile" "bin/prog")
                 "(\"owner\" sexp (\"profile\" \"bin/prog\"))"
                 "{\"name\":\"owner\",\"format\":\"sexp\",\"operands\":[\"profile\", \"bin/prog\"]}")
  (check-command command-verify? #("verify" "pkg-a")
                 "(\"verify\" sexp (\"pkg-a\"))"
                 "{\"name\":\"verify\",\"format\":\"sexp\",\"operands\":[\"pkg-a\"]}")
  (check-command command-help? #()
                 "(\"help\" sexp ())"
                 "{\"name\":\"help\",\"format\":\"sexp\",\"operands\":[]}")
  ;; --format rides along on the new commands too.
  (check-command command-why? #("why" "pkg-a" "--format" "json")
                 "(\"why\" json (\"pkg-a\"))"
                 "{\"name\":\"why\",\"format\":\"json\",\"operands\":[\"pkg-a\"]}")
  ;; Wrong arity refuses; unknown commands exit 2 (D-008).
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("plan"))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("hold" "profile" "pkg-a"))
                'no-error))
  (check-equal? (pm-error-exit-code
                 (with-handlers ([exn:fail:pm? (lambda (e) e)])
                   (parse-args #("frobnicate"))
                   'no-error))
                2)

  ;; ---------------------------------------------------------------
  ;; docs/API.org is the golden (E-26). Every "** =pm ...=" header is
  ;; re-parsed and re-rendered here, so a documented example that
  ;; drifts from the real --format json output fails the gate.
  (define-runtime-path cli-dir ".")
  (define api-path
    (simplify-path (build-path cli-dir 'up "docs" "API.org")))
  (check-true (file-exists? api-path) "docs/API.org must exist")
  (define api-lines (file->string api-path))
  (define (api-examples text)
    ;; -> (listof (list command-line json-string)), in document order.
    (let loop ([ls (string-split text "\n")] [acc '()])
      (cond
        [(null? ls) (reverse acc)]
        [(regexp-match #rx"^\\*\\* =pm (.+)=\\s*$" (car ls))
         => (lambda (m)
              (define line (cadr m))
              (define rest (cdr ls))
              (define next (and (pair? rest) (car rest)))
              (cond
                ;; string-prefix? here is racket/base's PATTERN form:
                ;; (string-prefix? STRING PATTERN), not the string one.
                [(and next (string-prefix? next ": "))
                 (loop (cdr rest)
                       (cons (list line (substring next 2)) acc))]
                [else (loop rest acc)]))]
        [else (loop (cdr ls) acc)])))
  (define examples (api-examples api-lines))
  ;; Sixteen commands plus --help.
  (check-equal? (length examples) 17)
  (check-equal? (sort (remove-duplicates
                       (map (lambda (e)
                              (let ([words (string-split (car e) " ")])
                                (define w (if (string=? (car words) "pm")
                                              (cadr words)
                                              (car words)))
                                ;; "pm --help" documents the help command.
                                (if (string=? w "--help") "help" w)))
                            examples))
                     string<?)
               (sort (append (map car command-table)
                             (list "check" "help"))
                     string<?))
  (for ([ex (in-list examples)])
    (define words (string-split (car ex) " "))
    (define argv
      (list->vector
       (if (and (pair? words) (string=? (car words) "pm"))
           (cdr words)
           words)))
    (check-equal? (command->json (parse-args argv))
                  (cadr ex)
                  (string-append "docs/API.org is stale for: " (car ex))))
  (delete-directory/files check-dir))
