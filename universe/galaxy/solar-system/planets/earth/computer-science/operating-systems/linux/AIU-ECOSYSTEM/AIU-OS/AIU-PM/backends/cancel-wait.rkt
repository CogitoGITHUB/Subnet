#lang racket/base
;; cancel-wait.rkt -- decide how a child ended: its exit code, a
;; cancellation, or a death, and put every wait through the narrated wait
;; door. It must not spawn a process, collect output, or touch the fifo.

(require "../core/errors.rkt"
         "../core/verbose.rkt"
         "status-fifo.rkt")

(provide
 ;; string (listof string) (listof string) -> never returns, kind 'cancelled
 raise-cancelled
 ;; channel evt (-> any) -> string or 'cancelled or 'died or 'killed
 wait-command
 ;; the wait door: narrate first, block second, reap the tree on a break
 await-status-line)

;; ---------------------------------------------------------------------------
;; Cancellation

;; string (listof string) (listof string) -> never returns, kind 'cancelled
;; operation completed remaining-state
(define (raise-cancelled operation completed remaining)
  (raise-pm-error 'cancelled 'run-command "cancelled"
                  #:fields `(("operation" . ,operation)
                             ("completed" . ,completed)
                             ("remaining-state" . ,remaining))))

;; ---------------------------------------------------------------------------
;; The single decision point.

;; channel evt (-> any) -> string or 'cancelled or 'died, the single
;; decision point. A ready status line wins (even with cancel: finished
;; work counts; channel-try-get is a state check, not a wait). Cancel
;; kills the tree through kill-thunk. EOF or a KILLED line without cancel
;; is a death (caller raises with its kind). No clocks.
(define (wait-command line-ch cancel kill-thunk)
  (define (decide value)
    (cond [(eof-object? value) 'died]
          [(status-line-exit-code value) value]
          [(status-line-killed? value) 'killed]
          [else 'died]))
  (define outcome
    (sync (handle-evt line-ch (lambda (v) (list 'line v)))
          (handle-evt cancel (lambda (_) (list 'cancelled)))))
  (define ruling
    (if (eq? (car outcome) 'line)
        (decide (cadr outcome))
        'cancelled))
  (cond [(string? ruling) ruling]
        [(eq? ruling 'cancelled)
         (define pending (channel-try-get line-ch))
         (if (and pending (string? pending))
             (let ([r (decide pending)])
               (if (string? r) r (begin (kill-thunk) 'cancelled)))
             (begin (kill-thunk) 'cancelled))]
        [else (kill-thunk) 'cancelled]))

;; ---------------------------------------------------------------------------
;; The wait door (D-041). A blocking operation records itself BEFORE it
;; blocks, so a hang always leaves a last word on disk; that is why the
;; child wait is narrated here rather than blocked in silence.

;; path-string channel (or/c evt? #f) (-> any) exact-int custodian -> any
(define (await-status-line exe line-ch cancel kill-tree pgid cust)
  (with-handlers ([exn:break?
                   (lambda (e)
                     (kill-tree pgid)
                     (custodian-shutdown-all cust)
                     (raise e))])
    (wait-for 'run "child process exits"
              (string-append
               "the wrapper writes EXIT:<code> to the status fifo as "
               "its last act, so nothing about this result is "
               "knowable until that process is gone")
              #:how (string-append
                       "exe=" (if (path? exe) (path->string exe) exe))
              (lambda ()
                (wait-command line-ch (or cancel never-evt)
                              (lambda () (kill-tree pgid)))))))

(module+ test
  (require rackunit
           "../core/cancel.rkt")

  ;; wait-command decision matrix, no children: line wins, EOF without a
  ;; line is died, cancel kills through the given thunk exactly once.
  (define matrix-line (make-channel))
  (void (thread (lambda () (channel-put matrix-line "EXIT:0"))))
  (check-equal? (wait-command matrix-line never-evt
                              (lambda () (error "must not kill")))
                "EXIT:0")
  (define matrix-cancelled (make-channel))
  (define killed-box (box #f))
  (define-values (matrix-cancel matrix-fire!) (make-cancel-source))
  (matrix-fire!)
  (check-equal? (wait-command matrix-cancelled matrix-cancel
                              (lambda () (set-box! killed-box #t)))
                'cancelled)
  (check-true (unbox killed-box))
  ;; A line that arrived with cancel still counts as completion.
  (define matrix-both (make-channel))
  (void (thread (lambda () (channel-put matrix-both "EXIT:5"))))
  (check-equal? (wait-command matrix-both matrix-cancel
                              (lambda () (error "must not kill")))
                "EXIT:5"))
