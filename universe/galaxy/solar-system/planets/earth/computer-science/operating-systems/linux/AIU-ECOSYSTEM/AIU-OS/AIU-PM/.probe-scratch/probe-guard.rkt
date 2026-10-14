#lang racket/base
;; .probe-scratch/probe-guard.rkt -- scratch probe, NOT committed.
;; Decisive experiment: does a fresh-custodian guard around each
;; run-command call reclaim the leaked fds? Compares the fd count
;; with and without the guard.

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "../backends/run.rkt")

(define (fd-count)
  (length (directory-list "/proc/self/fd")))

(define (emit tag v)
  (fprintf (current-error-port) "~a: ~a\n" tag v)
  (flush-output (current-error-port)))

(define sh-exe (find-executable-path "sh"))
(define cwd (path->string (current-directory)))

;; A: unguarded, 60 calls
(define a0 (fd-count))
(for ([i (in-range 60)])
  (run-command sh-exe '("-c" "exit 0")
               #:cwd cwd #:kind 'build #:operation "unguarded"))
(define a1 (fd-count))
(emit "A-unguarded"
      (format "fds ~a->~a delta=~a (~a/call)"
              a0 a1 (- a1 a0) (/ (- a1 a0) 60.0)))

;; B: guarded with a fresh custodian per call, 60 calls
(define b0 (fd-count))
(for ([i (in-range 60)])
  (define cust (make-custodian))
  (parameterize ([current-custodian cust])
    (run-command sh-exe '("-c" "exit 0")
                 #:cwd cwd #:kind 'build #:operation "guarded"))
  (custodian-shutdown-all cust))
(define b1 (fd-count))
(emit "B-guarded"
      (format "fds ~a->~a delta=~a (~a/call)"
              b0 b1 (- b1 b0) (/ (- b1 b0) 60.0)))

;; C: guarded, but custodian made and shutdown INSIDE the
;; parameterize (so the shutdown runs while cust is current)
(define c0 (fd-count))
(for ([i (in-range 60)])
  (parameterize ([current-custodian (make-custodian)])
    (run-command sh-exe '("-c" "exit 0")
                 #:cwd cwd #:kind 'build #:operation "guarded2")
    (custodian-shutdown-all (current-custodian))))
(define c1 (fd-count))
(emit "C-guarded-inside"
      (format "fds ~a->~a delta=~a (~a/call)"
              c0 c1 (- c1 c0) (/ (- c1 c0) 60.0)))

(emit "done" "guard probe complete")
