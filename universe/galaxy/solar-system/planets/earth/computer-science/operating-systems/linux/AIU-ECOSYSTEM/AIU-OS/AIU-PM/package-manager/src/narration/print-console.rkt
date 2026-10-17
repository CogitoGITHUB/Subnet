#lang racket/base
;; ui.rkt -- the only module that prints user-facing output.

(require racket/contract/base
         "../errors/error-type.rkt"
         "./event-text.rkt")

(provide (contract-out
          ;; exn:fail:pm -> void, clean message only (E-7)
          [display-pm-error (->* (exn:fail:pm?) (#:port output-port?) void?)]
          ;; exn:fail? -> void, bug banner, message and context (E-7)
          [display-internal-error (->* (exn:fail?) (#:port output-port?) void?)]
          ;; string -> void, collect MSG and log it at warning level (E-11)
          [warn! (-> string? void?)]
          ;; -> void, print collected warnings oldest-first, then count (E-11)
          [display-warning-summary (->* () (#:port output-port?) void?)]
          ;; (listof string) -> void, the SUCCESS path. Results go out
          ;; of this module exactly like errors do (D-036, V-3): one
          ;; printer for the user, never one per command.
          [display-result (->* ((listof string?)) (#:port output-port?) void?)]
          ;; (output-port (listof string)) -> void, the same printer with
          ;; an explicit port. run.rkt's legacy fallback writes to
          ;; stderr and has no other way to say so.
          [display-result-to (-> output-port? (listof string?) void?)]
          ;; Parameter holding a box of collected warning strings, newest first.
          ;; Scope it with parameterize; warn! adds, display-warning-summary reads.
          [current-collected-warnings (parameter/c (box/c (listof string?)))]))

;; ---------------------------------------------------------------------------
;; Warning collection (E-11)

;; Parameter of (Boxof (Listof String)), newest warning first.
(define current-collected-warnings (make-parameter (box '())))

;; string -> void, collect MSG and log it at warning level (E-11)
(define (warn! msg)
  (define box (current-collected-warnings))
  (set-box! box (cons msg (unbox box)))
  (log-pm-warning "~a" msg))

;; -> void, print collected warnings oldest-first, then the count (E-11)
(define (display-warning-summary #:port [port (current-error-port)])
  (define warnings (reverse (unbox (current-collected-warnings))))
  (for ([w (in-list warnings)])
    (fprintf port "warning: ~a\n" w))
  (define n (length warnings))
  (fprintf port "~a warning~a\n" n (if (= n 1) "" "s")))

;; ---------------------------------------------------------------------------
;; Error display (E-7)

;; exn:fail:pm -> void, clean message only, no stack trace (E-7)
(define (display-pm-error e #:port [port (current-error-port)])
  (displayln (exn-message e) port))

;; exn:fail? -> void, bug banner, message and context (E-7)
(define (display-internal-error e #:port [port (current-error-port)])
  (displayln "internal error: this is a bug in the package manager;" port)
  (displayln "please report it with the context below." port)
  (displayln (exn-message e) port)
  (fprintf port "  context: ~s\n"
           (continuation-mark-set->context (exn-continuation-marks e))))

;; ---------------------------------------------------------------------------
;; Result display (V-3). Errors have had one printer since E-7; results
;; now get the same treatment so no command prints by itself. The
;; narration of WHY something happened goes to core/verbose.rkt; what
;; the user asked for goes out of here.

;; (listof string) -> void, one line per item, oldest first, nothing
;; else. An empty list prints nothing at all rather than a blank line.
(define (display-result lines #:port [port (current-output-port)])
  (for ([l (in-list lines)])
    (displayln l port))
  (flush-output port))

(define (display-result-to port lines)
  (display-result lines #:port port))

;; ---------------------------------------------------------------------------
