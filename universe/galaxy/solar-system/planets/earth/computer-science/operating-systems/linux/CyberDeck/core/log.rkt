#lang racket/base
;; log.rkt -- the single logger; the debug log always gets the full exception.

(require racket/contract/base
         racket/logging
         racket/match)

(define-logger pm)

(provide pm-logger
         log-pm-debug log-pm-info log-pm-warning log-pm-error
         (contract-out
          ;; path-string (-> any) -> any, runs thunk with pm debug log to file (E-10)
          [call-with-log-file (-> path-string? (-> any) any)]
          ;; exn -> void, full message and context at debug (E-10)
          [log-pm-exn (-> exn? void?)]))

;; ---------------------------------------------------------------------------
;; File logging (E-8, E-10)

;; path-string (-> any) -> any
;; Run THUNK with pm debug events written to PATH (truncated first).
;; Events are drained after THUNK returns, so nothing is lost.
(define (call-with-log-file path thunk)
  (define receiver (make-log-receiver pm-logger 'debug))
  (define out (open-output-file path #:exists 'truncate/replace))
  (define (drain)
    (let loop ()
      (match (sync/timeout 0 receiver)
        [#f (void)]
        [(vector level message _ ...)
         (fprintf out "[~a] ~a\n" level message)
         (loop)])))
  (dynamic-wind void thunk (lambda () (drain) (close-output-port out))))

;; exn -> void, full message and context at debug (E-10)
(define (log-pm-exn e)
  (log-pm-debug "~a\n  context: ~s"
                (exn-message e)
                (continuation-mark-set->context (exn-continuation-marks e))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file)

  ;; The thunk value passes through and its debug output lands in the file.
  (define log-path (make-temporary-file "pm-log-test~a"))
  (check-equal?
   (call-with-log-file log-path
                       (lambda () (log-pm-debug "hello ~a" 42) 'done-res))
   'done-res)
  (check-true
   (regexp-match? #rx"hello 42" (file->string log-path)))

  ;; Full exceptions land in the file with their context.
  (call-with-log-file log-path
                      (lambda ()
                        (with-handlers ([exn:fail? log-pm-exn])
                          (error "kaboom"))))
  (check-true
   (regexp-match? #rx"kaboom" (file->string log-path)))
  (check-true
   (regexp-match? #rx"context:" (file->string log-path)))
  (delete-file log-path))
