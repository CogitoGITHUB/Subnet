#lang racket/base
;; .probe-scratch/probe-leak2.rkt -- scratch probe, NOT committed.
;; Does NOT require backends/run.rkt (its owner is mid-edit). Attributes
;; the 3-fds-per-run-command leak to a specific process* shape:
;;   A: bare (process* ...) + 'wait, no close-*   <- make-status-fifo!
;;   B: same but all three ports closed           <- make-killer's shape
;;   C: process* inside a custodian                <- what run.rkt does for
;;                                                   the drainers

(require racket/file
         racket/list
         racket/path
         racket/system)

(define (fd-count) (length (directory-list "/proc/self/fd")))

(define (emit tag v)
  (fprintf (current-error-port) "~a: ~a\n" tag v)
  (flush-output (current-error-port)))

(define mkfifo-exe (find-executable-path "mkfifo"))
(define tmp (make-temporary-directory "pm-probe2~a"))

(emit "A/limit-soft" (with-handlers ([exn:fail? (lambda (_) "?")])
                      (file->string "/proc/self/limits")))
(emit "start-fds" (fd-count))

;; A: exactly what make-status-fifo! does today.
(define a0 (fd-count))
(for ([i (in-range 20)])
  (define maker (process* (path->string mkfifo-exe)
                          (build-path tmp (string-append "a" (number->string i)))))
  ((list-ref maker 4) 'wait))
(emit "A-after-20" (fd-count))
(emit "A-delta-per-call" (/ (- (fd-count) a0) 20.0))

;; B: the same spawn with the three ports closed (make-killer's shape).
(define b0 (fd-count))
(for ([i (in-range 20)])
  (define maker (process* (path->string mkfifo-exe)
                          (build-path tmp (string-append "b" (number->string i)))))
  ((list-ref maker 4) 'wait)
  (close-input-port (list-ref maker 0))
  (close-output-port (list-ref maker 1))
  (close-input-port (list-ref maker 3)))
(emit "B-after-20" (fd-count))
(emit "B-delta-per-call" (/ (- (fd-count) b0) 20.0))

;; C: after a Racket GC, do the A fds get collected? (Racket may close
;; subprocess ports on reap -- this says whether it does.)
(collect-garbage)
(collect-garbage)
(emit "C-after-2x-gc" (fd-count))

(delete-directory/files tmp)
(emit "done" "ok")
