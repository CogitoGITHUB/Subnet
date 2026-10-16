#lang racket/base
;; status-fifo.rkt -- the status fifo protocol: create the fifo, open the
;; read end, and say what a status line may contain. It must not spawn a
;; child, kill a tree, or decide what the line means.

(require racket/file
         racket/string
         racket/system
         "../errors/error-type.rkt")

(provide
 ;; path-string path-string symbol -> void, mkfifo or kind 'config
 make-status-fifo!
 ;; string -> (or exact-nonnegative-integer? #f), the code an EXIT line carries
 status-line-exit-code
 ;; string -> boolean, did the wrapper report a signal instead of an exit?
 status-line-killed?
 ;; path-string channel -> thread, the ONE reader of the read end
 open-status-line)

;; ---------------------------------------------------------------------------
;; What a status line may contain. Three shapes and no more: the exit code
;; the wrapper's own command produced, the signal that killed the wrapper,
;; and this parent's report that the read end could not be opened at all.

(define exit-line-rx #rx"^EXIT:([0-9]+)$")
(define killed-line-rx #rx"^KILLED:")

;; Never a line and never printed raw: it is what the channel carries when
;; the open below raised, so a failed open reads as a death with a reason.
(define opener-failed-prefix "OPENER-FAILED: ")

;; string -> (or exact-nonnegative-integer? #f)
(define (status-line-exit-code line)
  (define m (regexp-match exit-line-rx line))
  (and m (string->number (cadr m))))

;; string -> boolean
(define (status-line-killed? line)
  (regexp-match? killed-line-rx line))

;; ---------------------------------------------------------------------------
;; The fifo itself.

;; The mkfifo executable arrives from the spawn path, which already looked
;; every helper up; a second lookup here would be a second place to raise.
;;
;; path-string path-string symbol -> void, mkfifo or kind 'config when missing
;; The three ports process* hands back MUST be closed, exactly as the tree
;; killer closes its own. This runs once per subprocess call, so leaving
;; them open leaks three file descriptors on EVERY call, for ever:
;; measured at exactly 3.0 per call, and collect-garbage reclaims none of
;; them. A long apply makes hundreds of calls, the descriptor table fills,
;; and the process then fails in ways that have nothing to do with the code
;; being debugged. That was the real shape of the 41-minute hang: the 100+
;; leaked fds in the evidence.
(define (make-status-fifo! mkfifo-exe fifo-path operation)
  (define maker (process* (path->string mkfifo-exe) fifo-path))
  ((list-ref maker 4) 'wait)
  (close-input-port (list-ref maker 0))
  (close-output-port (list-ref maker 1))
  (close-input-port (list-ref maker 3))
  (unless (file-exists? fifo-path)
    (raise-pm-error 'config 'run-command "could not create status fifo"
                    #:fields `(("operation" . ,operation))))
  (void))

;; ---------------------------------------------------------------------------
;; The read end.

;; path-string channel -> thread
;;
;; The read end opens in its own thread: opening blocks until the
;; wrapper's first act, and blocking inside open() is a block, not a
;; raise, so no handler in this process can catch it.
;;
;; The opener is the ONLY thing that ever puts on the channel. So when a
;; run has no cancel, this thread is that run's entire wake path: if it
;; raised -- the status file was never created, or cannot be opened --
;; nothing would wake the wait and the process would park for ever,
;; silently, which from the outside is indistinguishable from a slow
;; program. That is the silent block the law forbids.
;;
;; So every exit goes on the channel, failure included: the line reader
;; maps anything that is not EXIT:n to a death and the caller raises, so
;; a failed open becomes a reported error instead of an eternal wait.
(define (open-status-line status-path line-ch)
  (thread
   (lambda ()
     (with-handlers
         ([exn?
           (lambda (e)
             (channel-put line-ch
                          (string-append opener-failed-prefix
                                         (exn-message e))))])
       (define in (open-input-file status-path))
       (define line (read-line in 'any))
       (close-input-port in)
       (channel-put line-ch line)))))
