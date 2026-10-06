#lang racket/base
;; main.rkt -- the pm command line: check specs plus help text.
;; Thin over the core verbs; every failure becomes an exit code here
;; (E-5 narrow handlers, E-15 codes). Plan and apply subcommands wait
;; for spec-to-plan derivation (a later phase); W-8 noted in help.

(require racket/contract/base
         racket/file
         racket/string
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

(struct command-check (dir) #:transparent)
;; dir : string?  directory holding .rktd files (as given on argv)

(struct command-help () #:transparent)
;; no fields: print help text

;; any -> boolean, a parsed command value
(define (command? v)
  (or (command-check? v) (command-help? v)))

;; ---------------------------------------------------------------------------
;; Parsing (hand-rolled: two commands fit in a cond, no extra deps)

;; (vectorof string) -> command
(define (parse-args argv)
  (define args (vector->list argv))
  (cond [(null? args) (command-help)]
        [(and (= (length args) 1)
              (member (car args) '("--help" "-h")))
         (command-help)]
        [(and (= (length args) 2) (string=? (car args) "check"))
         (command-check (cadr args))]
        [(and (pair? args) (string=? (car args) "check"))
         (raise-pm-error 'config 'pm "check takes exactly one directory"
                         #:fields `(("args" . ,(string-join args " "))))]
        [else
         (raise-pm-error 'config 'pm "unknown command"
                         #:fields `(("args" . ,(string-join args " ")))
                         #:hint "try `pm --help`")]))

;; -> void, prints usage to stdout
(define (display-help)
  (displayln "usage: pm check DIR | pm --help")
  (displayln "")
  (displayln "  check DIR   validate every .rktd file, print ok lines")
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
  (define code
    (with-handlers ([exn:break? (lambda (_) 130)]
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
  (check-exn exn:fail:contract?
             (lambda () (parse-args '("check" "x"))))

  ;; Checking: a good file prints ok and exits 0.
  (define check-dir (make-temporary-directory "pm-cli~a"))
  (call-with-output-file (build-path check-dir "good.rktd")
    (lambda (port)
      (displayln "(spec (format-version 1) (name demo) (version \"1.0\")" port)
      (displayln "  (summary \"s\")" port)
      (displayln "  (source (git \"https://example.org/d.git\"" port)
      (displayln "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))" port)
      (displayln "  (build (steps (byte-compile)))" port)
      (displayln "  (install (emacs (autoloads \"a.el\")))" port)
      (displayln "  (license mit) (homepage \"https://example.org\"))" port)))
  (define check-out (open-output-string))
  (check-equal? (parameterize ([current-output-port check-out])
                  (run-check check-dir))
                0)
  (check-regexp-match #rx"ok: demo 1.0" (get-output-string check-out))

  ;; A bad file prints its error and exits 3; others still checked.
  (call-with-output-file (build-path check-dir "bad.rktd")
    (lambda (port)
      (displayln "(spec (format-version 1) (bogus 1))" port)))
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
