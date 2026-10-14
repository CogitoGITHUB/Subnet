#lang racket/base
;; .probe-scratch/probe-fd-diff.rkt -- scratch probe, NOT committed.
;; Identifies WHICH fds leak per run-command call: snapshots the
;; /proc/self/fd table (fd -> readlink target) before and after one
;; call, then prints the difference.

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "../backends/run.rkt")

;; -> (hash fd-number -> target-string), the fd table snapshot
(define (fd-table)
  (define h (make-hash))
  (for ([e (in-list (directory-list "/proc/self/fd"))])
    (define n (string->number (path->string (file-name-from-path e))))
    (define target
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (let ([p (build-path "/proc/self/fd" (path->string e))])
          (define resolved (resolve-path p))
          (if resolved (path->string resolved) #f))))
    (when n (hash-set! h n (or target "?"))))
  h)

(define (emit tag v)
  (fprintf (current-error-port) "~a: ~a\n" tag v)
  (flush-output (current-error-port)))

(define sh-exe (find-executable-path "sh"))

;; Warm up: one throwaway call so any one-time init fds are already
;; present and do not pollute the diff.
(run-command sh-exe '("-c" "exit 0")
             #:cwd (path->string (current-directory))
             #:kind 'build #:operation "warm")

(emit "warm-fds" (hash-count (fd-table)))

;; Five calls, diffing the fd table each time.
(for ([i (in-range 5)])
  (define before (fd-table))
  (define res
    (run-command sh-exe '("-c" "exit 0")
                 #:cwd (path->string (current-directory))
                 #:kind 'build #:operation "diff"))
  (define after (fd-table))
  (emit (format "call-~a-exit" i) (run-result-exit res))
  ;; fds present in after but not before (leaked)
  (for ([(n tgt) (in-hash after)]
        #:when (not (hash-has-key? before n)))
    (emit (format "LEAK-fd-~a" n) tgt))
  ;; fds gone (closed, for completeness)
  (for ([(n tgt) (in-hash before)]
        #:when (not (hash-has-key? after n)))
    (emit (format "CLOSED-fd-~a" n) tgt))
  (emit (format "call-~a-count" i)
        (format "before=~a after=~a" (hash-count before) (hash-count after))))

(emit "done" "diff probe complete")
