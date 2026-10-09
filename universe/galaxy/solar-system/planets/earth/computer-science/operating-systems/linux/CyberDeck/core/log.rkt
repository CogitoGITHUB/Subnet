#lang racket/base
;; log.rkt -- the single logger; the debug log always gets the full exception.

(require racket/contract/base
         racket/logging
         racket/match
         racket/string
         racket/syntax
         ;; this Racket build does not export syntax-case from racket/base
         (for-syntax racket/base))

(define-logger pm)

(provide pm-logger
         log-pm-debug log-pm-info log-pm-warning log-pm-error
         with-trace trace-event
         trace-on? current-trace-depth
         trace-arg-string trace-redact
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
;; Tracing (D-021): choke points and test boundaries, no #lang rewrite.
;;
;; ONE structured record per IN / OUT / THW. The record goes through the
;; pm logger like every other observability record, so whatever drains
;; the log (file today, JSON Lines later) sees it unchanged. The screen
;; is a second receiver on the same logger: PM_TRACE=0 detaches the
;; screen only, the record is still written.
;;
;; Record shape, pipe-delimited so a reader needs no parser:
;;   TRACE <IN|OUT|THW> <depth> <name> ms=<int> <payload>
;; payload is args=..., values=..., or exn=...
;;
;; No timers, no sleeps, no polling: the screen drain is sync/timeout 0,
;; which never waits -- it only picks up records already queued.

;; monotonic origin; ms are integer and never go backwards
(define trace-origin-ms (current-inexact-monotonic-milliseconds))

;; any -> exact-integer, milliseconds since module load, monotonic
(define (trace-ms)
  (inexact->exact
   (round (- (current-inexact-monotonic-milliseconds) trace-origin-ms))))

(define current-trace-depth (make-parameter 0))

;; any -> string, the one rendering every trace payload goes through
(define trace-arg-string
  (case-lambda
    [(a) (cond [(path? a) (path->string a)]
               [(string? a) a]
               [(symbol? a) (symbol->string a)]
               [else (format "~a" a)])]))

;; any -> string, passwords in URLs become *** (S-8)
(define (trace-redact a)
  (regexp-replace* #rx"://[^/:@ \t]+:[^/@ \t]+@"
                   (trace-arg-string a)
                   "://***@"))

;; any -> string, redacted then bounded so one record cannot flood
(define (trace-render v)
  (define s (trace-redact v))
  (if (> (string-length s) 200)
      (string-append (substring s 0 200) "...")
      s))

;; (listof any) -> string, "a b c" of redacted bounded items
(define (trace-render-list vs)
  (string-join (map trace-render vs) " "))

;; symbol any string -> void, the single record path
(define (trace-event kind name payload)
  (log-pm-debug "TRACE ~a ~a ~a ms=~a ~a"
                kind (current-trace-depth) name (trace-ms) payload))

;; screen receiver, drained without waiting
(define trace-screen-receiver (make-log-receiver pm-logger 'debug))

;; any -> boolean, default from PM_TRACE (0 = screen off, records stay)
(define (trace-on-default)
  (not (string=? (or (getenv "PM_TRACE") "1") "0")))

;; A parameter, not a bare function, so tests and callers flip the screen
;; without touching the process environment.
(define trace-on? (make-parameter (trace-on-default)))

;; string -> string, drops the "pm: " prefix the logger prepends
(define (trace-strip-prefix message)
  (regexp-replace #rx"^[A-Za-z][A-Za-z0-9_-]*: " message ""))

;; void -> void, drains queued records to the screen; never blocks
;; Screen line: [TRACE] <2*(depth-1) spaces> IN|OUT|THW name ms=N ...
(define (trace-screen-drain!)
  (when (trace-on?)
    (let loop ()
      (match (sync/timeout 0 trace-screen-receiver)
        [#f (void)]
        [(vector _ message _ ...)
         (define bare (trace-strip-prefix message))
         ;; Only trace records get the depth indent; anything else that
         ;; shares the logger is labelled [LOG] so the two never mix.
         (if (regexp-match? #rx"^TRACE " bare)
             (eprintf "[TRACE] ~a~a\n"
                      (make-string (* 2 (max 0 (sub1 (current-trace-depth))))
                                   #\space)
                      (regexp-replace #rx"^TRACE " bare ""))
             (eprintf "[LOG] ~a\n" bare))
         (loop)]))))

;; string symbol (listof any) -> void, one IN/OUT record plus its screen
(define (trace-record kind name vs)
  ;; symbols, not strings: case compares with eqv?
  (define field (case kind [(OUT) "values"] [(IN) "args"] [else "exn"]))
  (trace-event kind name (format "~a=~a" field (trace-render-list vs)))
  (trace-screen-drain!))

;; symbol (-> (listof any)) (-> any) -> any
;; Records IN, then OUT with the body's values, or THW and re-raise.
(define (call-with-trace name arg-thunk body-thunk)
  (parameterize ([current-trace-depth (add1 (current-trace-depth))])
    (trace-record 'IN name (arg-thunk))
    (with-handlers
        ([exn? (lambda (e)
                 (trace-record 'THW name (list (exn-message e)))
                 (raise e))])
      (call-with-values body-thunk
                        (lambda vs
                          (trace-record 'OUT name vs)
                          (apply values vs))))))

;; with-trace : (f arg ...) body ... -> any
;; The only tracing form callers write. Wraps the body, so it works
;; around internal defines and needs no restructuring of the function.
(define-syntax (with-trace stx)
  (syntax-case stx ()
    [(_ (f a ...) body ...)
     #'(call-with-trace 'f (lambda () (list a ...)) (lambda () body ...))]
    ;; dotted: (f . args) binds args to the whole argument list
    [(_ (f . a) body ...)
     #'(call-with-trace 'f (lambda () a) (lambda () body ...))]))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/system)

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
  (delete-file log-path)

  ;; --- tracing (D-021) ---------------------------------------------------
  ;; Synthetic names only (T-10). The record is what the logger sees, so
  ;; the trace is captured the same way as any other observability record.

  ;; IN then OUT, in that order, both naming the function.
  (define order-path (make-temporary-file "pm-trace-order~a"))
  (check-equal?
   (call-with-log-file order-path
                       (lambda ()
                         (with-trace (pkg-alpha-build 1 "b")
                           'built)))
   'built)
  (define order-lines
    (filter (lambda (l) (regexp-match? #rx"TRACE " l))
            (string-split (file->string order-path) "\n")))
  (check-equal? (length order-lines) 2)
  (check-true (regexp-match? #rx"TRACE IN 1 pkg-alpha-build ms=[0-9]+ args=1 b"
                             (car order-lines)))
  (check-true (regexp-match? #rx"TRACE OUT 1 pkg-alpha-build ms=[0-9]+ values=built"
                             (cadr order-lines)))

  ;; THW on raise, and the exception still propagates.
  (define throw-path (make-temporary-file "pm-trace-throw~a"))
  (define caught
    (call-with-log-file
     throw-path
     (lambda ()
       (with-handlers ([exn? values])
         (with-trace (pkg-beta-fetch "boom")
           (error "no such ref"))
         'no-raise))))
  (check-pred exn:fail? caught)
  (check-equal? (exn-message caught) "no such ref")
  (define throw-lines
    (filter (lambda (l) (regexp-match? #rx"TRACE " l))
            (string-split (file->string throw-path) "\n")))
  (check-equal? (length throw-lines) 2)
  (check-true (regexp-match? #rx"TRACE IN 1 pkg-beta-fetch" (car throw-lines)))
  (check-true (regexp-match? #rx"TRACE THW 1 pkg-beta-fetch" (cadr throw-lines)))
  ;; A raised function records no OUT.
  (check-false (regexp-match? #rx"TRACE OUT" (string-join throw-lines "\n")))

  ;; Redaction is on the record path: a url with a password never lands raw.
  (define redact-path (make-temporary-file "pm-trace-redact~a"))
  (void
   (call-with-log-file
    redact-path
    (lambda ()
      (with-trace (pkg-gamma-clone "https://user:s3cret@example.org/p.git")
        'ok))))
  (define redact-text (file->string redact-path))
  (check-false (regexp-match? #rx"s3cret" redact-text))
  (check-true (regexp-match? #rx"://[*][*][*]@" redact-text))

  ;; Nesting raises depth on the inner records only.
  (define depth-path (make-temporary-file "pm-trace-depth~a"))
  (void
   (call-with-log-file
    depth-path
    (lambda ()
      (with-trace (pkg-delta-outer)
        (with-trace (pkg-delta-inner)
          'deep)))))
  (define depth-text (file->string depth-path))
  (check-true (regexp-match? #rx"TRACE IN 1 pkg-delta-outer" depth-text))
  (check-true (regexp-match? #rx"TRACE IN 2 pkg-delta-inner" depth-text))

  ;; A traced function returning several values keeps them all.
  (define multi-path (make-temporary-file "pm-trace-multi~a"))
  (check-equal?
   (call-with-values
    (lambda ()
      (call-with-log-file multi-path
                          (lambda ()
                            (with-trace (pkg-cycle-a-split)
                              (values 1 2 3)))))
    list)
   '(1 2 3))
  (check-true
   (regexp-match? #rx"TRACE OUT 1 pkg-cycle-a-split ms=[0-9]+ values=1 2 3"
                  (file->string multi-path)))

  ;; The screen is the record rendered: depth-indented, one line each.
  (define screen-out (open-output-string))
  (parameterize ([current-error-port screen-out])
    (void (call-with-trace 'pkg-screen-probe (lambda () '("a")) (lambda () 'r))))
  (define screen-lines
    (filter (lambda (l) (string-prefix? l "[TRACE]"))
            (string-split (get-output-string screen-out) "\n")))
  (check-equal? (length screen-lines) 2)
  (check-true
   (regexp-match? #rx"^\\[TRACE\\] IN 1 pkg-screen-probe ms=[0-9]+ args=a$"
                  (car screen-lines)))
  (check-true
   (regexp-match? #rx"^\\[TRACE\\] OUT 1 pkg-screen-probe ms=[0-9]+ values=r$"
                  (cadr screen-lines)))
  ;; Nesting indents by two spaces per level.
  (define nest-out (open-output-string))
  (parameterize ([current-error-port nest-out])
    (void (call-with-trace 'pkg-nest-outer (lambda () '())
                           (lambda ()
                             (call-with-trace 'pkg-nest-inner (lambda () '())
                                              (lambda () 'v))))))
  (define nest-lines
    (filter (lambda (l) (string-prefix? l "[TRACE]"))
            (string-split (get-output-string nest-out) "\n")))
  (check-true
   (for/or ([l (in-list nest-lines)])
     (regexp-match? #rx"^\\[TRACE\\]   IN 2 pkg-nest-inner ms=" l)))
  ;; PM_TRACE=0 silences the screen; the record is still logged.
  (define quiet-path (make-temporary-file "pm-trace-quiet~a"))
  (define quiet-out (open-output-string))
  (check-equal?
   (parameterize ([trace-on? #f])
     (call-with-log-file
      quiet-path
      (lambda ()
        (parameterize ([current-error-port quiet-out])
          (void (call-with-trace 'pkg-quiet-probe (lambda () '("x"))
                                 (lambda () 'y)))))))
   (void))
  (check-equal? (get-output-string quiet-out) "")
  (check-true (regexp-match? #rx"TRACE IN 1 pkg-quiet-probe"
                             (file->string quiet-path)))
  ;; The env default is what PM_TRACE=0 selects.
  (check-true (trace-on-default))
  (delete-file quiet-path)

  (for ([p (in-list (list order-path throw-path redact-path depth-path
                           multi-path))])
    (delete-file p)))
