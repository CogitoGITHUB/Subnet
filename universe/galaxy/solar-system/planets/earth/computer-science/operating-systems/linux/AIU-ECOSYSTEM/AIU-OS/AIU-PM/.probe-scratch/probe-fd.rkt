#lang racket/base
;; .probe-scratch/probe-fd.rkt -- scratch probe, NOT committed.
;; Question (a): do pipe fds accumulate per run-command call?
;; Counts /proc/self/fd entries around repeated run-command calls.
;; No writers, no new spawns of its own beyond the run-command
;; calls under test.

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "../backends/run.rkt")

;; -> exact-nonnegative-integer, how many fds this process holds
(define (fd-count)
  (length (directory-list "/proc/self/fd")))

;; string any -> void, one line, flush forced
(define (emit tag v)
  (fprintf (current-error-port) "~a: ~a\n" tag v)
  (flush-output (current-error-port)))

(emit "start-fds" (fd-count))

;; 1) the simplest possible command: sh -c exit 0
(define sh-exe (find-executable-path "sh"))
(define git-exe (find-executable-path "git"))

(emit "sh-exe" sh-exe)
(emit "git-exe" git-exe)

;; Loop A: sh -c "exit 0" x40
(for ([i (in-range 40)])
  (define before (fd-count))
  (define res
    (run-command sh-exe '("-c" "exit 0")
                 #:cwd (path->string (current-directory))
                 #:kind 'build
                 #:operation "probe-sh"))
  (define after (fd-count))
  (emit (format "sh-~a" i)
        (format "exit=~a fds ~a->~a (delta ~a)"
                (run-result-exit res) before after (- after before))))

(emit "after-sh-fds" (fd-count))

;; Loop B: git --version x40 (git is what the e2e fixtures run)
(for ([i (in-range 40)])
  (define before (fd-count))
  (define res
    (run-command git-exe '("--version")
                 #:cwd (path->string (current-directory))
                 #:kind 'fetch
                 #:operation "probe-git"))
  (define after (fd-count))
  (emit (format "git-~a" i)
        (format "exit=~a fds ~a->~a (delta ~a)"
                (run-result-exit res) before after (- after before))))

(emit "after-git-fds" (fd-count))

;; Loop C: a command that writes a lot to stdout (pipe stress)
(for ([i (in-range 40)])
  (define before (fd-count))
  (define res
    (run-command sh-exe '("-c" "seq 1 500")
                 #:cwd (path->string (current-directory))
                 #:kind 'build
                 #:operation "probe-seq"))
  (define after (fd-count))
  (emit (format "seq-~a" i)
        (format "exit=~a lines=~a fds ~a->~a (delta ~a)"
                (run-result-exit res)
                (length (run-result-stdout-lines res))
                before after (- after before))))

(emit "after-seq-fds" (fd-count))
(emit "done" "probe complete")
