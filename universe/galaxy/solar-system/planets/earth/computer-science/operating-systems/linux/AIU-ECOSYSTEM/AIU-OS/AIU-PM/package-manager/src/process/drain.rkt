#lang racket/base
;; drain.rkt -- read a child's stdout/stderr line by line: redact it,
;; forward it to the log port and to on-progress, keep a bounded tail.
;; It must not spawn a process, wait for one, or judge the outcome.

(require racket/list
         racket/string
         "progress.rkt")

(provide
 ;; When set, full output streams here line by line (bounded memory).
 current-run-log-port
 ;; string -> string, URL passwords and secret assignments removed (S-8)
 redact-credentials
 ;; input-port (or #f output-port) box exact-int (or #f (-> string any))
 ;; -> thread, reads until EOF
 drain-thread
 ;; input-port (or #f output-port) exact-int (or #f (-> string any))
 ;; -> (listof string), oldest-first bounded tail plus log forwarding
 collect-lines)

;; Where the full text goes while a run is open. #f keeps it in the
;; bounded tail only.
(define current-run-log-port (make-parameter #f))

;; ---------------------------------------------------------------------------
;; Redaction (S-8): URL passwords and secret assignments never reach logs.

;; string -> string
(define (redact-credentials s)
  (define no-url-pass
    (regexp-replace* #rx"://[^/@]+:[^/@]*@" s "://<redacted>@"))
  (regexp-replace* #rx"(?i:((token|passwd|password|secret)[\"']?[ \t]*[:=][ \t]*))[^ \t\n]+"
                   no-url-pass
                   "\\1<redacted>"))

;; ---------------------------------------------------------------------------
;; Output collection: bounded tail buffer, full text to the log port, one
;; on-progress call per line when given. Drain threads end on EOF, which is
;; an event, never a clock.

;; input-port (or #f output-port) box exact-int (or #f (-> string any)) -> thread
(define (drain-thread in log-port lines-box limit on-progress)
  (thread
   (lambda ()
     (let loop ()
       (define line (read-line in 'any))
       (unless (eof-object? line)
         (define clean (redact-credentials line))
         (when log-port
           (displayln clean log-port))
         (when on-progress
           (on-progress clean))
         (set-box! lines-box
                   (bounded-tail (cons clean (unbox lines-box)) limit))
         (loop))))))

;; input-port (or #f output-port) exact-int (or #f (-> string any))
;; -> (listof string), oldest-first bounded tail plus log forwarding
(define (collect-lines in log-port limit on-progress)
  (let loop ([grown '()])
    (define line (read-line in 'any))
    (if (eof-object? line)
        (reverse grown)
        (let ([clean (redact-credentials line)])
          (when log-port (displayln clean log-port))
          (when on-progress (on-progress clean))
          (loop (bounded-tail (cons clean grown) limit))))))
