#lang racket/base
;; main.rkt -- the pm command line: check specs plus help text.
;; Thin over the core verbs; every failure becomes an exit code here
;; (E-5 narrow handlers, E-15 codes). Plan and apply subcommands wait
;; for spec-to-plan derivation (a later phase); W-8 noted in help.

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
 (contract-out
  ;; any -> boolean, a parsed command value
  [command? (-> any/c boolean?)]
  ;; (vectorof string) -> command, bad usage raises kind 'config
  [parse-args (-> (vectorof string?) command?)]
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

;; any -> boolean, a parsed command value
(define (command? v)
  (or (command-check? v) (command-help? v)))

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

;; -> void, prints usage to stdout
(define (display-help)
  (displayln "usage: pm [--format sexp|json] check DIR | pm --help")
  (displayln "")
  (displayln "  check DIR   validate every .rktd file, print ok lines")
  (displayln "  --format    output shape, sexp (default) or json")
  (displayln "  --help      print this text")
  (displayln "")
  (displayln "Plan and apply subcommands arrive with spec-to-plan")
  (displayln "derivation in a later phase."))

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
             (run-check (command-check-dir cmd))])))
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
  (delete-directory/files check-dir))
