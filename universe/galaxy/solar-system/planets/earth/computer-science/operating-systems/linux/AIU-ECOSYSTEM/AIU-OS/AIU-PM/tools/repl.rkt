#lang racket/base
;; tools/repl.rkt -- a persistent Racket namespace for this project.
;;
;; WHY: on this phone a bare `racket -n -e ''` measures anywhere between
;; 0.29s and 1.12s for the SAME empty program. That spread is filesystem
;; variance under proot, not compute. Paying it once and staying resident
;; beats any packaging change.
;;
;; HOW: load the project's core modules once, then accept expressions on
;; stdin and print each result. After the first line, probes are
;; microseconds instead of a fresh process.
;;
;; Use: racket tools/repl.rkt, then type one expression per line.
;; No timers, no polling, no sleeps (D-015): the loop blocks on read-line
;; and EOF (#f) is the only exit.

(require racket/file
         racket/pretty
         racket/string)

(define *core*
  (list "package-manager/src/errors/error-type.rkt"
        "package-manager/src/git/git-commit.rkt"
        "package-manager/src/git/git-env.rkt"
        "package-manager/src/git/vault-lock.rkt"
        "package-manager/src/spec/version.rkt"
        "package-manager/src/spec/spec.rkt"
        "package-manager/src/spec/spec-read.rkt"
        "package-manager/src/spec/resolve.rkt"
        "package-manager/src/spec/plan.rkt"
        "package-manager/src/narration/print-console.rkt"
        "package-manager/src/narration/event-text.rkt"
        "package-manager/src/store/lockfile.rkt"
        "package-manager/src/machine/cancel.rkt"))

(printf "CyberDeck REPL. Loading ~a core modules...\n" (length *core*))
(flush-output)

;; Load up front so per-probe cost stays near zero. A module that fails
;; is reported by name and skipped, so one broken file cannot take the
;; whole REPL down.
;; Probe into a dedicated namespace, so the project's own bindings are
;; visible. dynamic-require would load a module but leave its exports in
;; THAT module's namespace; evaluating a require form inside ns attaches
;; them to the namespace the probes run in.
(define *ns* (make-base-namespace))

(for ([m (in-list *core*)])
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (printf "SKIP ~a: ~a\n" m (exn-message e))
          (flush-output))])
    (eval `(require (file ,(path->string (path->complete-path m)))) *ns*)
    (printf "  loaded ~a\n" m)
    (flush-output)))

(printf "ready. One expression per line; blank and ; lines ignored.\n")
(flush-output)

(define (eval-line line)
  (define v
    (eval (read (open-input-string line)) *ns*))
  (unless (void? v) (pretty-write v))
  (flush-output))

;; The loop: read-line is the only wait, EOF is the only exit.
(let loop ()
  (define line (read-line (current-input-port) 'any))
  (cond
    [(eof-object? line)
     (printf "\nbye.\n")
     (flush-output)]
    [(or (string=? (string-trim line) "") (string-prefix? (string-trim line) ";"))
     (loop)]
    [else
     (with-handlers
         ([exn:fail? (lambda (e)
                       (printf "ERROR ~a\n" (exn-message e))
                       (flush-output))]
          [void? (lambda () (void))])
       (eval-line line))
     (loop)]))
