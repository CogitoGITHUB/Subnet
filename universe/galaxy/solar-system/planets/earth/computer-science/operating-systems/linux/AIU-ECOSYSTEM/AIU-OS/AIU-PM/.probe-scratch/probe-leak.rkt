#lang racket/base
;; .probe-scratch/probe-leak.rkt -- scratch probe, NOT committed.
;; Pin WHICH process* in run.rkt leaks: make-status-fifo!'s bare
;; (process* mkfifo) + 'wait with no close-*, or the main spawn.
;; Also: is this proot (run.rkt's comments say so)?

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "../backends/run.rkt")

(define (fd-count) (length (directory-list "/proc/self/fd")))

(define (fd-kinds)
  (sort (for/list ([p (in-list (directory-list "/proc/self/fd"))]
                   #:unless (regexp-match? #rx"^[0-9]+$" (path->string p)))
         (define t (path->string p))
         (cond [(regexp-match? #rx"pipe:" t) "pipe"]
               [(regexp-match? #rx"fifo" t) "fifo"]
               [(regexp-match? #rx"anon_inode" t) "anon"]
               [else "other"]))
        string<?))

(define (emit tag v)
  (fprintf (current-error-port) "~a: ~a\n" tag v)
  (flush-output (current-error-port)))

;; --- is this proot? -------------------------------------------------
(emit "proot-trace" (file->string "/proc/self/cmdline"))
(emit "cmdline" (file->string "/proc/self/cmdline"))

(define sh-exe (find-executable-path "sh"))
(define mkfifo-exe (find-executable-path "mkfifo"))
(define tmp (make-temporary-directory "pm-probe~a"))
(define fifo (build-path tmp "status.fifo"))

(emit "start-fds" (fd-count))
(emit "start-kinds" (fd-kinds))

;; --- A: bare process* + wait, NO close (what make-status-fifo! does) -
(emit "A-before" (fd-count))
(for ([i (in-range 20)])
  (define maker (process* (path->string mkfifo-exe)
                          (string-append (path->string fifo) (number->string i))))
  ((list-ref maker 4) 'wait))
(emit "A-after" (fd-count))
(emit "A-delta" (- (fd-count) 20))
(emit "A-kinds" (fd-kinds))

;; --- B: same but closing all three ports (the correct shape) -------
(emit "B-before" (fd-count))
(for ([i (in-range 20)])
  (define maker (process* (path->string mkfifo-exe)
                          (string-append (path->string tmp)
                                         (string-append "/b" (number->string i)))))
  ((list-ref maker 4) 'wait)
  (close-input-port (list-ref maker 0))
  (close-output-port (list-ref maker 1))
  (close-input-port (list-ref maker 3)))
(emit "B-after" (fd-count))
(emit "B-delta" (- (fd-count) 20))
(emit "B-kinds" (fd-kinds))

;; --- C: threads left alive after run-command ------------------------
(define before-threads (length (current-process-milliseconds)))
(emit "C-marks" before-threads)
(define sh-fd-before (fd-count))
(for ([i (in-range 10)])
  (run-command sh-exe '("-c" "exit 0")
               #:cwd tmp #:kind 'build #:operation "probe"))
(emit "C-runcommand-delta-over-10" (- (fd-count) sh-fd-before))
(emit "C-kinds" (fd-kinds))

(delete-directory/files tmp)
(emit "done" "ok")
