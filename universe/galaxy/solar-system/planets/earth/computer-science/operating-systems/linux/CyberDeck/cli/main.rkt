#lang racket/base
;; main.rkt -- the pm command line: one command per stage, each with
;; --format sexp|json. Thin over the core verbs; every failure becomes
;; an exit code here (E-5 narrow handlers, E-15 codes). Parsing plus
;; command rendering land here (E-18a); execution wiring arrives per
;; command after that, and unwired commands refuse loudly at dispatch.

(require racket/contract/base
         racket/file
         racket/string
         "../core/cancel.rkt"
         "../core/errors.rkt"
         "../core/spec.rkt"
         "../core/spec-read.rkt"
         "../core/ui.rkt"
         "../core/version.rkt")

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

;; any -> boolean, a parsed command value
(define (command? v)
  (or (command-check? v) (command-help? v)
      (command-plan? v) (command-lock? v) (command-fetch? v)
      (command-apply? v) (command-update? v) (command-activate? v)
      (command-rollback? v) (command-remove? v) (command-hold? v)
      (command-why? v) (command-owner? v) (command-verify? v)))

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
        (list "verify" 1 (lambda (ops fmt) (command-verify (car ops) fmt)))))

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
        [(command-help? cmd) (list "help" 'sexp '())]
        [else (raise-pm-error 'internal 'pm "not a command"
                              #:fields `(("value" . ,(format "~s" cmd))))]))

;; command -> string, stable sexp shape for goldens
(define (command->sexp cmd)
  (format "~s" (command->datum cmd)))

;; command -> string, fixed key order until E-26 hardens the schema.
;; Operands render through ~s, which matches JSON for the ASCII paths
;; and names commands take today.
(define (command->json cmd)
  (define d (command->datum cmd))
  (string-append "{\"name\":" (format "~s" (car d))
                 ",\"format\":" (format "~s" (symbol->string (cadr d)))
                 ",\"operands\":["
                 (string-join (map (lambda (o) (format "~s" o)) (caddr d))
                              ", ")
                 "]}"))

;; -> void, prints usage to stdout
(define (display-help)
  (displayln "usage: pm [--format sexp|json] COMMAND [ARGS] | pm --help")
  (displayln "")
  (displayln "  check DIR          validate every .rktd file, print ok lines")
  (displayln "  plan SPECDIR       show the install plan (not executable yet)")
  (displayln "  lock LOCKFILE      show the lockfile plan (not executable yet)")
  (displayln "  fetch MANIFEST     fetch all declared packages (not yet)")
  (displayln "  apply STATEDIR     apply a plan (not executable yet)")
  (displayln "  update STATEDIR    check all packages (not executable yet)")
  (displayln "  activate PROFILE   flip the profile (not executable yet)")
  (displayln "  rollback PROFILE N repoint at generation N (not yet)")
  (displayln "  remove PROFILE PKG unlink a package (not executable yet)")
  (displayln "  hold PROFILE PKG SLOT pin a slot (not executable yet)")
  (displayln "  why NAME           explain a package (not executable yet)")
  (displayln "  owner PROFILE REL  who owns a path (not executable yet)")
  (displayln "  verify NAME        re-check a tree (not executable yet)")
  (displayln "  --format           output shape, sexp (default) or json")
  (displayln "  --help             print this text"))

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
  (unless (directory-exists? dir)
    (raise-pm-error 'config 'pm "directory not found"
                    #:fields `(("dir" . ,dir))))
  (define failures
    (for/fold ([bad 0]) ([f (in-list (sorted-rktd-files dir))])
      (with-handlers ([exn:fail:pm?
                       (lambda (e)
                         (display-pm-error e)
                         (+ bad 1))])
        (define s (read-spec-file f))
        (printf "ok: ~a ~a\n"
                (spec-name s) (version->string (spec-version s)))
        bad)))
  (if (zero? failures) 0 3))

;; ---------------------------------------------------------------------------
(module+ main
  (define-values (cancel-evt trigger-cancel!) (make-cancel-source))
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
      (define cmd (parse-args (current-command-line-arguments)))
      (cond [(command-help? cmd) (display-help) 0]
            [(command-check? cmd)
             (run-check (command-check-dir cmd))]
            [else
             (raise-pm-error 'config 'pm "command not executable yet"
                             #:fields `(("command" . ,(car (command->datum cmd)))))])))
  (exit code))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
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
  (delete-directory/files check-dir))
