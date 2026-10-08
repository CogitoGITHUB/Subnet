#lang racket/base
;; run.rkt -- one place that spawns subprocesses (F-2): argv lists only,
;; explicit cwd, allowlisted env, whole-tree kill on cancel. Every wait ends
;; on an EVENT (child status line, EOF, or cancel); there are no timeouts,
;; no polls, no sleeps anywhere here (D-015). A hung operation is visible
;; (last progress event) and ended by explicit cancel, never by a clock.
;;
;; The completion signal is a status line the wrapper writes to a fifo as
;; its last act (EXIT:<code>), never the process waiter: under this proot,
;; (ctl 'wait) misses deaths of setsid-wrapped children that exit fast
;; (measured ~7/8 misses), while direct children are fine. The wrapper
;; opens the fifo first and writes last, so the line cannot be missed;
;; death before the open strands only the opener thread, which cancel
;; reaps through the custodian. Exit codes come from the parsed line
;; (setsid itself exits 0). Pipe EOF starvation is handled by redirect
;; mode, whose files always reach EOF.

(require racket/contract/base
         racket/system
         racket/string
         racket/file
         "../core/errors.rkt")

(provide (struct-out run-result)
 (contract-out
  ;; Lines of tail output kept per stream; default 20.
  [current-captured-lines (parameter/c exact-positive-integer?)]
  ;; When set, full output streams here line by line (bounded memory).
  [current-run-log-port (parameter/c (or/c #f output-port?))]
  ;; exe argv #:cwd #:kind #:operation [#:env #:cancel #:on-progress]
  ;; -> result; ends on child status line, EOF, or cancel (D-015)
  [run-command
   (->* (path-string? (listof string?)
         #:cwd path-string?
         #:kind pm-kind/c
         #:operation string?)
        (#:env (listof (cons/c string? string?))
         #:cancel (or/c evt? #f)
         #:on-progress (or/c (-> string? any/c) #f))
        run-result?)]
  ;; Same contract through output files instead of pipes: immune to
  ;; pipe-EOF starvation (batch tools whose output pipes never close).
  [run-command/redirect
   (->* (path-string? (listof string?)
         #:cwd path-string?
         #:kind pm-kind/c
         #:operation string?)
        (#:env (listof (cons/c string? string?))
         #:cancel (or/c evt? #f)
         #:on-progress (or/c (-> string? any/c) #f))
        run-result?)]))

(struct run-result (exit stdout-lines stderr-lines) #:transparent)
;; exit         : exact-integer?    process exit code
;; stdout-lines : (listof string?)  last N lines, oldest first
;; stderr-lines : (listof string?)  last N lines, oldest first

(define current-captured-lines (make-parameter 20))
(define current-run-log-port (make-parameter #f))

;; ---------------------------------------------------------------------------
;; Environment (S-6): fixed allowlist, everything else dropped.

;; Fixed variable names passed to every child.
(define fixed-env-names
  '("PATH" "HOME" "LANG" "SSH_AUTH_SOCK"
    "http_proxy" "https_proxy" "HTTP_PROXY" "HTTPS_PROXY"
    "no_proxy" "NO_PROXY"))

;; (listof (cons string string)) -> void, bad names are our bug (internal)
(define (check-env-names extras)
  (for ([p (in-list extras)])
    (unless (regexp-match? #rx"^[A-Za-z_][A-Za-z0-9_]*$" (car p))
      (raise-pm-error 'internal 'run-command "invalid environment variable name"
                      #:fields `(("name" . ,(car p)))))))

;; (listof (cons string string)) -> (listof string), NAME=value assignments
(define (env-assignments extras)
  (define table (make-hash))
  (for ([n (in-list fixed-env-names)])
    (define v (getenv n))
    (when v (hash-set! table n v)))
  (for ([p (in-list extras)])
    (hash-set! table (car p) (cdr p)))
  (hash-map table (lambda (n v) (string-append n "=" v))))

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
                   (let ((b (cons clean (unbox lines-box))))
                     (if (> (length b) limit)
                         (reverse (cdr (reverse b)))
                         b)))
         (loop))))))

;; input-port (or #f output-port) exact-int (or #f (-> string any))
;; -> (listof string), oldest-first bounded tail plus log forwarding
(define (collect-lines in log-port limit on-progress)
  (let loop ([grown '()])
    (define line (read-line in 'any))
    (if (eof-object? line)
        (reverse grown)
        (let ((clean (redact-credentials line)))
          (when log-port (displayln clean log-port))
          (when on-progress (on-progress clean))
          (define next (cons clean grown))
          (loop (if (> (length next) limit)
                    (reverse (cdr (reverse next)))
                    next))))))

;; ---------------------------------------------------------------------------
;; Spawning with whole-tree kill on cancel.
;; Racket process groups are unavailable under proot
;; (subprocess-group-enabled -> #f, probed 2026-10-06), so children launch
;; via setsid (own process group) and die via pkill -g on cancel.
;; make-environment-variables also segfaults under this proot (probed
;; 2026-10-06), so the allowlist is enforced with env -i instead. Values
;; passed here are visible in ps output; never pass secrets via #:env.
;; The wrapper opens the status fifo FIRST (as its first act), traps
;; TERM/INT into a KILLED line, runs the command, and always ends with an
;; EXIT line carrying the command's own code. Spawn failure raises
;; synchronously with the cause attached.

;; -> path, helper binary or kind 'config when missing
(define (find-helper name)
  (or (find-executable-path name)
      (raise-pm-error 'config 'run-command "helper executable missing"
                      #:fields `(("helper" . ,name)))))

;; string, the wrapper all children run under. Argv carries the fifo path,
;; the executable and its arguments, so no shell quoting is ever needed.
;; The single write end is opened first and closed last: a reader can
;; neither strand in open (a writer is guaranteed) nor see early EOF (the
;; writer outlives every read). Racket fifo reads with zero writers return
;; EOF at once, so this ordering is load-bearing, not incidental.
(define status-script
  (string-append
   "fifo=\"$1\"; shift; exe=\"$1\"; shift; "
   "exec 3>\"$fifo\" || exit 99; "
   "trap 'echo \"KILLED:$?\" >&3' TERM INT; "
   "\"$exe\" \"$@\"; st=$?; echo \"EXIT:$st\" >&3"))

;; path-string string -> void, mkfifo or kind 'config when missing/failed
(define (make-status-fifo! fifo-path operation)
  (define mkfifo-exe (find-helper "mkfifo"))
  (define maker (process* (path->string mkfifo-exe) fifo-path))
  ((list-ref maker 4) 'wait)
  (unless (file-exists? fifo-path)
    (raise-pm-error 'config 'run-command "could not create status fifo"
                    #:fields `(("operation" . ,operation))))
  (void))

;; path-string -> string, argv text with paths rendered
(define (command-text exe argv)
  (string-join
   (map (lambda (a) (if (path? a) (path->string a) a))
        (cons (if (path? exe) (path->string exe) exe) argv))
   " "))

;; string (listof string) (listof string) -> never returns, kind 'cancelled
;; operation completed remaining-state
(define (raise-cancelled operation completed remaining)
  (raise-pm-error 'cancelled 'run-command "cancelled"
                  #:fields `(("operation" . ,operation)
                             ("completed" . ,completed)
                             ("remaining-state" . ,remaining))))

;; channel evt (-> any) -> string or 'cancelled or 'died, the single
;; decision point. A ready status line wins (even with cancel: finished
;; work counts; channel-try-get is a state check, not a wait). Cancel
;; kills the tree through kill-thunk. EOF or a KILLED line without cancel
;; is 'died (caller raises with its kind). No clocks.
(define (wait-command line-ch cancel kill-thunk)
  (define (decide value)
    (cond [(eof-object? value) 'died]
          [(regexp-match? #rx"^EXIT:([0-9]+)$" value) value]
          [(regexp-match? #rx"^KILLED:" value) 'killed]
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
         (if (and pending (pair? pending) (string? (cadr pending)))
             (let ((r (decide (cadr pending))))
               (if (string? r) r (begin (kill-thunk) 'cancelled)))
             (begin (kill-thunk) 'cancelled))]
        [else (kill-thunk) 'cancelled]))

;; path-string (listof string) string string pm-kind string
;; (listof (cons string string)) -> (values setsid pkill env sh exe-string
;; temp-dir status-path)
(define (spawn-prelude exe argv cwd kind operation extras)
  (check-env-names extras)
  (define setsid-exe (find-helper "setsid"))
  (define pkill-exe (find-helper "pkill"))
  (define env-exe (find-helper "env"))
  (define sh-exe (find-helper "sh"))
  (unless (file-exists? exe)
    (raise-pm-error 'config 'run-command "executable not found"
                    #:fields `(("exe" . ,exe))))
  (define exe-string (if (path? exe) (path->string exe) exe))
  ;; Atomic exclusive create (mkdtemp): uniqueness never comes from a clock.
  (define temp-dir (make-temporary-directory "pm-run~a"))
  (define status-path (build-path temp-dir "status.fifo"))
  (make-status-fifo! (path->string status-path) operation)
  (values setsid-exe pkill-exe env-exe sh-exe exe-string temp-dir status-path))

;; path setsid env sh exe-string (listof string) (listof pairs) string
;; string -> (list any), spawn or raise kind 'config synchronously
(define (spawn-wrapped status-path setsid-exe env-exe sh-exe exe-string argv
                       extras cwd operation)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (raise-pm-error 'config 'run-command "spawn failed"
                                     #:fields `(("operation" . ,operation)
                                                ("command" . ,(command-text
                                                               exe-string argv)))
                                     #:cause e))])
    (parameterize ([current-directory cwd])
      (apply process* (path->string setsid-exe)
             (append (list (path->string env-exe) "-i")
                     (env-assignments extras)
                     (list (path->string sh-exe) "-c" status-script "sh"
                           (path->string status-path)
                           exe-string)
                     (map (lambda (a) (if (path? a) (path->string a) a))
                          argv))))))

;; path -> (-> exact-int void), tree killer closing its own ports
(define (make-killer pkill-exe)
  (lambda (pgid)
    (define killer
      (process* (path->string pkill-exe) "-KILL" "-g"
                (number->string pgid)))
    ((list-ref killer 4) 'wait)
    (close-input-port (list-ref killer 0))
    (close-output-port (list-ref killer 1))
    (close-input-port (list-ref killer 3))))

;; ---------------------------------------------------------------------------
;; Pipe mode (default): concurrent drain threads. PRECONDITION: the child
;; must not orphan pipe holders (a daemonized grandchild keeps our pipes
;; open past the EXIT line and the drainers would never finish). Tools
;; that fork like that use redirect mode instead (proven by the daemon test).

;; path-string (listof string) -> run-result
;; exe argv cwd kind operation extras cancel on-progress
(define (run-command exe argv
                      #:cwd cwd
                      #:kind kind
                      #:operation operation
                      #:env [extras '()]
                      #:cancel [cancel #f]
                      #:on-progress [on-progress #f])
  (define-values (setsid-exe pkill-exe env-exe sh-exe exe-string
                             temp-dir status-path)
    (spawn-prelude exe argv cwd kind operation extras))
  (define limit (current-captured-lines))
  (define log-port (current-run-log-port))
  (define out-box (box '()))
  (define err-box (box '()))
  (define cust (make-custodian))
  (define line-ch (make-channel))
  (define kill-tree (make-killer pkill-exe))
  (define (command-failed what)
    (raise-pm-error kind 'run-command what
                    #:fields `(("operation" . ,operation)
                               ("command" . ,(command-text exe argv)))))
  (dynamic-wind
    void
    (lambda ()
      (define r
        (spawn-wrapped status-path setsid-exe env-exe sh-exe exe-string argv
                       extras cwd operation))
      (define out-port (list-ref r 0))
      (define in-port (list-ref r 1))
      (define pgid (list-ref r 2))
      (define err-port (list-ref r 3))
      (close-output-port in-port)
      (define start-ms (print-run-start exe argv cwd pgid))
      (define cancelled-here
        (lambda ()
          (kill-tree pgid)
          (custodian-shutdown-all cust)
          (print-run-end exe "cancelled" start-ms)
          (raise-cancelled operation
                           '("spawned" "tree killed")
                           '("no result" "pipes closed"))))
      (parameterize ([current-custodian cust])
        (define out-drainer
          (drain-thread out-port log-port out-box limit on-progress))
        (define err-drainer
          (drain-thread err-port log-port err-box limit on-progress))
        ;; The read end opens in its own thread: opening blocks until the
        ;; wrapper's first act, and the wrapper is guaranteed to act (it
        ;; opens before anything else can fail).
        (define opener
          (thread
           (lambda ()
             (define in (open-input-file status-path))
             (define line (read-line in 'any))
             (close-input-port in)
             (channel-put line-ch line))))
        (define outcome
          (with-handlers ([exn:break?
                           (lambda (e)
                             (kill-tree pgid)
                             (custodian-shutdown-all cust)
                             (raise e))])
            (if cancel
                (wait-command line-ch cancel
                              (lambda () (kill-tree pgid)))
                (wait-command line-ch never-evt
                              (lambda () (kill-tree pgid))))))
        (cond [(string? outcome)
               (define code (string->number
                             (cadr (regexp-match #rx"^EXIT:([0-9]+)$"
                                                 outcome))))
               (thread-wait out-drainer)
               (thread-wait err-drainer)
               (close-input-port out-port)
               (close-input-port err-port)
               (when log-port (flush-output log-port))
               (print-run-end exe (format "exit:~a" code) start-ms)
               (run-result code
                           (reverse (unbox out-box))
                           (reverse (unbox err-box)))]
              [(eq? outcome 'cancelled) (cancelled-here)]
              [else
               (custodian-shutdown-all cust)
               (print-run-end exe "no-status" start-ms)
               (command-failed "child died without status line")])))
    (lambda ()
      (when (directory-exists? temp-dir)
        (delete-directory/files temp-dir)))))

;; ---------------------------------------------------------------------------
;; File redirect mode: same wait logic, output collected from files at the
;; end (immune to pipe-EOF starvation). Temp files die on every exit path;
;; tails stay bounded; secrets stay redacted.

;; string -> string, two digits, zero-padded
(define (two-digits n)
  (if (< n 10)
      (string-append "0" (number->string n))
      (number->string n)))

;; -> string, UTC stamp for START lines (display only, D-015)
(define (utc-stamp)
  (define d (seconds->date (current-seconds) #t))
  (format "~a-~a-~aT~a:~a:~aZ"
          (date-year d)
          (two-digits (date-month d))
          (two-digits (date-day d))
          (two-digits (date-hour d))
          (two-digits (date-minute d))
          (two-digits (date-second d))))

;; any -> string, paths and values to plain text
(define (arg-string a)
  (cond [(path? a) (path->string a)]
        [(string? a) a]
        [else (format "~a" a)]))

;; string -> string, passwords in URLs become *** (S-8)
(define (redact-arg a)
  (regexp-replace* #rx"://[^/:@ \t]+:[^/@ \t]+@"
                   (arg-string a)
                   "://***@"))

;; path-string (listof string) path-string exact-integer
;; -> exact-integer, START line plus the start time
(define (print-run-start exe argv cwd pgid)
  (eprintf "pm-run-start ~a cwd=~a pid=~a ~a ~a\n"
           (utc-stamp) (arg-string cwd) pgid
           (arg-string exe)
           (string-join (map redact-arg argv) " "))
  (flush-output (current-error-port))
  (current-inexact-monotonic-milliseconds))

;; path-string string exact-integer -> void, END line
(define (print-run-end exe outcome start-ms)
  (define ms (inexact->exact
              (round (- (current-inexact-monotonic-milliseconds)
                        start-ms))))
  (eprintf "pm-run-end ~a after=~ams ~a\n" outcome ms (arg-string exe))
  (flush-output (current-error-port)))

;; path-string (listof string) -> run-result, batch tools via files
(define (run-command/redirect exe argv
                              #:cwd cwd
                              #:kind kind
                              #:operation operation
                              #:env [extras '()]
                              #:cancel [cancel #f]
                              #:on-progress [on-progress #f])
  (define-values (setsid-exe pkill-exe env-exe sh-exe exe-string
                             temp-dir status-path)
    (spawn-prelude exe argv cwd kind operation extras))
  (define limit (current-captured-lines))
  (define log-port (current-run-log-port))
  (define out-path (build-path temp-dir "out.log"))
  (define err-path (build-path temp-dir "err.log"))
  (define cust (make-custodian))
  (define line-ch (make-channel))
  (define kill-tree (make-killer pkill-exe))
  (define (command-failed what)
    (raise-pm-error kind 'run-command what
                    #:fields `(("operation" . ,operation)
                               ("command" . ,(command-text exe argv)))))
  (dynamic-wind
    void
    (lambda ()
      (define out-file
        (open-output-file out-path #:exists 'truncate/replace))
      (define err-file
        (open-output-file err-path #:exists 'truncate/replace))
      (define in-file (open-input-file "/dev/null"))
      (define r
        (parameterize ([current-directory cwd])
          (apply process*/ports out-file in-file err-file
                 (path->string setsid-exe)
                 (append (list (path->string env-exe) "-i")
                         (env-assignments extras)
                         (list (path->string sh-exe) "-c" status-script "sh"
                               (path->string status-path)
                               exe-string)
                         (map (lambda (a) (if (path? a) (path->string a) a))
                              argv)))))
      (define pgid (list-ref r 2))
      (close-input-port in-file)
      (define start-ms (print-run-start exe argv cwd pgid))
      (define cancelled-here
        (lambda ()
          (kill-tree pgid)
          (custodian-shutdown-all cust)
          (print-run-end exe "cancelled" start-ms)
          (raise-cancelled operation
                           '("spawned" "tree killed")
                           '("no result" "temp files removed"))))
      (parameterize ([current-custodian cust])
        (define opener
          (thread
           (lambda ()
             (define in (open-input-file status-path))
             (define line (read-line in 'any))
             (close-input-port in)
             (channel-put line-ch line))))
        (define outcome
          (with-handlers ([exn:break?
                           (lambda (e)
                             (kill-tree pgid)
                             (custodian-shutdown-all cust)
                             (raise e))])
            (if cancel
                (wait-command line-ch cancel
                              (lambda () (kill-tree pgid)))
                (wait-command line-ch never-evt
                              (lambda () (kill-tree pgid))))))
        (cond [(string? outcome)
               (define code (string->number
                             (cadr (regexp-match #rx"^EXIT:([0-9]+)$"
                                                 outcome))))
               (close-output-port out-file)
               (close-output-port err-file)
               (print-run-end exe (format "exit:~a" code) start-ms)
               (run-result code
                           (call-with-input-file out-path
                             (lambda (p) (collect-lines p log-port limit on-progress)))
                           (call-with-input-file err-path
                             (lambda (p) (collect-lines p log-port limit on-progress))))]
              [(eq? outcome 'cancelled) (cancelled-here)]
              [else
               (custodian-shutdown-all cust)
               (print-run-end exe "no-status" start-ms)
               (command-failed "child died without status line")])))
    (lambda ()
      (when (directory-exists? temp-dir)
        (delete-directory/files temp-dir)))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/string
           "../core/errors.rkt"
           "../core/cancel.rkt")

  (define sh-exe (find-executable-path "sh"))
  (define echo-exe (find-executable-path "echo"))
  (define ps-exe (find-executable-path "ps"))
  (define mkfifo-exe (find-executable-path "mkfifo"))
  (define cwd (current-directory))

  (define (run-ok exe argv)
    (run-command exe argv
                 #:cwd cwd #:kind 'fetch #:operation "test"))

  ;; Basic success: exit code and split streams.
  (define basic (run-ok echo-exe '("hi")))
  (check-equal? (run-result-exit basic) 0)
  (check-equal? (run-result-stdout-lines basic) '("hi"))
  (check-equal? (run-result-stderr-lines basic) '())

  ;; Observability: START/END lines on the error port, flushed.
  (define obs-out (open-output-string))
  (parameterize ([current-error-port obs-out])
    (run-ok echo-exe '("watched")))
  (define obs-text (get-output-string obs-out))
  (check-regexp-match #rx"pm-run-start .*echo watched" obs-text)
  (check-regexp-match #rx"pm-run-end exit:0 after=[0-9]+ms" obs-text)

  ;; on-progress fires once per output line received.
  (define progress-lines (box '()))
  (run-command echo-exe '("one")
               #:cwd cwd #:kind 'fetch #:operation "test-progress"
               #:on-progress (lambda (line)
                               (set-box! progress-lines
                                         (cons line (unbox progress-lines)))))
  (check-equal? (length (unbox progress-lines)) 1)

  ;; File redirect mode: same shapes without pipes.
  (define (run-redirect-ok exe argv)
    (run-command/redirect exe argv
                          #:cwd cwd #:kind 'fetch
                          #:operation "test-redirect"))
  (define redirect-basic
    (run-redirect-ok echo-exe '("hi-redirect")))
  (check-equal? (run-result-exit redirect-basic) 0)
  (check-equal? (run-result-stdout-lines redirect-basic) '("hi-redirect"))
  (check-equal? (run-result-stderr-lines redirect-basic) '())

  ;; Redirect on-progress fires per collected line.
  (define redirect-progress (box '()))
  (run-command/redirect echo-exe '("a" "b")
                        #:cwd cwd #:kind 'fetch
                        #:operation "test-redirect-progress"
                        #:on-progress (lambda (line)
                                        (set-box! redirect-progress
                                                  (cons line (unbox redirect-progress)))))
  (check-equal? (length (unbox redirect-progress)) 1)

  ;; One fixture dir for the fifo barriers below. Barriers are rendezvous:
  ;; every fifo read end is opened while a writer is guaranteed present, so
  ;; no zero-writer window can strand a reader in open or return early EOF.
  (define barrier-dir (make-temporary-directory "pm-barrier~a"))
  (define (make-fifo! name)
    (define path (build-path barrier-dir name))
    (define maker (process* (path->string mkfifo-exe) (path->string path)))
    ((list-ref maker 4) 'wait)
    (check-true (file-exists? path))
    path)
  (define block-path (make-fifo! "block.fifo"))
  (define up-path (make-fifo! "up.fifo"))

  ;; Cancel before start: a fired source ends a fifo-blocked child at once.
  ;; The blocker holds the write end open from the start, so the child's
  ;; read end always has a writer; cancel (not EOF) ends the wait.
  (define block-held
    (open-output-file block-path #:exists 'update))
  (define-values (pre-cancel pre-trigger!) (make-cancel-source))
  (pre-trigger!)
  (define pre-cancelled
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (run-command sh-exe (list "-c"
                                   (string-append "read x < "
                                                  (path->string block-path)))
                   #:cwd cwd #:kind 'fetch #:operation "test-cancel-now"
                   #:cancel pre-cancel)
      'no-error))
  (check-pred cancelled-error? pre-cancelled)
  (check-regexp-match #rx"test-cancel-now" (exn-message pre-cancelled))
  (check-equal? (cdr (assoc "operation" (exn:fail:pm-fields pre-cancelled)))
                "test-cancel-now")
  (check-equal? (cdr (assoc "completed" (exn:fail:pm-fields pre-cancelled)))
                '("spawned" "tree killed"))
  (close-output-port block-held)

  ;; Cancel mid-flight through a barrier fifo: the child signals started
  ;; (writer held open by the fixture, so the signal cannot be lost), the
  ;; parent fires cancel, the tree dies, the error names the operation.
  (define up-held
    (open-output-file up-path #:exists 'update))
  (define up-in (open-input-file up-path))
  (define-values (mid-cancel mid-trigger!) (make-cancel-source))
  (define mid-result (make-channel))
  (void
   (thread
    (lambda ()
      (define outcome
        (with-handlers ([exn:fail:pm? (lambda (e) e)])
          (run-command sh-exe
                       (list "-c"
                             (string-append "echo up > "
                                            (path->string up-path)
                                            "; read x < "
                                            (path->string block-path)))
                       #:cwd cwd #:kind 'fetch #:operation "test-cancel-mid"
                       #:cancel mid-cancel)
          'no-error))
      (channel-put mid-result outcome))))
  (check-equal? (read-line up-in) "up")
  (close-input-port up-in)
  (close-output-port up-held)
  (mid-trigger!)
  (define mid-cancelled (channel-get mid-result))
  (check-pred cancelled-error? mid-cancelled)
  (check-regexp-match #rx"test-cancel-mid" (exn-message mid-cancelled))

  ;; The cancelled tree is really dead: recorded pids are gone from ps.
  ;; The child records its own and its child's pid before blocking.
  (define dead-block (make-fifo! "dead-block.fifo"))
  (define dead-held
    (open-output-file dead-block #:exists 'update))
  (define dead-pids (build-path barrier-dir "pids"))
  (define dead-up (make-fifo! "dead-up.fifo"))
  (define dead-up-held
    (open-output-file dead-up #:exists 'update))
  (define dead-up-in (open-input-file dead-up))
  (define-values (dead-cancel dead-trigger!) (make-cancel-source))
  (define dead-result (make-channel))
  (void
   (thread
    (lambda ()
      (define outcome
        (with-handlers ([exn:fail:pm? (lambda (e) e)])
          (run-command sh-exe
                       (list "-c"
                             (string-append "echo $$ > " (path->string dead-pids)
                                            "; sleep 60 & echo $! >> "
                                            (path->string dead-pids)
                                            "; echo up > "
                                            (path->string dead-up)
                                            "; read x < "
                                            (path->string dead-block)))
                       #:cwd cwd #:kind 'fetch #:operation "test-cancel-dead"
                       #:cancel dead-cancel)
          'no-error))
      (channel-put dead-result outcome))))
  ;; The up line arrives only after the child started, so the trigger
  ;; cannot precede it. No clocks.
  (check-equal? (read-line dead-up-in) "up")
  (close-input-port dead-up-in)
  (close-output-port dead-up-held)
  (dead-trigger!)
  (check-pred cancelled-error? (channel-get dead-result))
  (define pids
    (map string-trim
         (string-split (file->string dead-pids) "\n" #:trim? #f)))
  (define live
    (map string-trim
         (run-result-stdout-lines
          (run-ok ps-exe '("-eo" "pid=")))))
  (for ([p (in-list pids)]
        #:unless (string=? p ""))
    (check-false (if (member p live) #t #f) (format "survivor: ~a" p)))
  (close-output-port dead-held)

  ;; A daemonized grandchild is no longer special: completion is the EXIT
  ;; line, which arrives however long grandchildren live. The grandchild's
  ;; pid is recorded through a rendezvous fifo for exact reaping (never
  ;; pattern matching). Redirect mode: no pipe drainers to hold.
  (define gp-fifo (make-fifo! "gp.fifo"))
  (define gp-held
    (open-output-file gp-fifo #:exists 'update))
  (define gp-in (open-input-file gp-fifo))
  (define daemon-done
    (run-command/redirect sh-exe
                 (list "-c"
                       (string-append "setsid sh -c 'echo $$ > "
                                      (path->string gp-fifo)
                                      "; exec sleep 60 </dev/null >/dev/null 2>&1"
                                      "' & exit 7"))
                 #:cwd cwd #:kind 'fetch #:operation "test-daemon"))
  (check-equal? (run-result-exit daemon-done) 7)
  (define grandchild-pid (read-line gp-in))
  (close-input-port gp-in)
  (close-output-port gp-held)
  ;; Reap it by exact pid (recorded, never pattern-matched).
  (define reaper
    (process* "/usr/bin/sh" "-c"
              (string-append "kill -9 " grandchild-pid)))
  ((list-ref reaper 4) 'wait)
  (close-input-port (list-ref reaper 0))
  (close-output-port (list-ref reaper 1))
  (close-input-port (list-ref reaper 3))

  ;; Ctrl-C path: break-thread on a blocked run re-raises the break after
  ;; killing the tree (a break without a fired cancel source is external;
  ;; converting it would launder stray signals). The tree must be dead.
  (define break-block (make-fifo! "break-block.fifo"))
  (define break-held
    (open-output-file break-block #:exists 'update))
  (define break-up (make-fifo! "break-up.fifo"))
  (define break-up-held
    (open-output-file break-up #:exists 'update))
  (define break-up-in (open-input-file break-up))
  (define break-pid-file (build-path barrier-dir "break.pid"))
  (define break-result (make-channel))
  (define break-worker
    (thread
     (lambda ()
       (define outcome
         (with-handlers ([exn:break? (lambda (e) e)]
                         [exn:fail:pm? (lambda (e) e)])
           (run-command sh-exe
                        (list "-c"
                              (string-append "echo $$ > "
                                             (path->string break-pid-file)
                                             "; echo up > "
                                             (path->string break-up)
                                             "; read x < "
                                             (path->string break-block)))
                        #:cwd cwd #:kind 'fetch #:operation "test-break")
           'no-error))
       (channel-put break-result outcome))))
  (check-equal? (read-line break-up-in) "up")
  (close-input-port break-up-in)
  (close-output-port break-up-held)
  (break-thread break-worker)
  (define break-raised (channel-get break-result))
  (check-pred exn:break? break-raised)
  (define break-pid
    (string-trim (file->string break-pid-file)))
  (define break-live
    (map string-trim
         (run-result-stdout-lines
          (run-ok ps-exe '("-eo" "pid=")))))
  (check-false (if (member break-pid break-live) #t #f)
               (format "break survivor: ~a" break-pid))
  (close-output-port break-held)

  ;; Exit codes pass through.
  (check-equal? (run-result-exit
                 (run-ok sh-exe '("-c" "exit 3")))
                3)

  ;; Stdin is always empty: read gets EOF at once.
  (check-equal? (run-result-stdout-lines
                 (run-ok sh-exe '("-c" "read x || echo got-eof")))
                '("got-eof"))

  ;; Missing executable is kind 'config.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (run-ok "/nonexistent/pm-test-exe" '())))

  ;; Bad env names are our bug: kind 'internal.
  (check-exn exn:fail:pm?
             (lambda ()
               (run-command echo-exe '("hi")
                            #:cwd cwd #:kind 'fetch
                            #:operation "test"
                            #:env '(("HAS SPACE" . "x")))))

  ;; Spawn failure raises synchronously with the cause attached.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (run-command (build-path cwd "is-a-directory")
                             '()
                             #:cwd cwd #:kind 'fetch
                             #:operation "test-spawn-fail")))

  ;; Secrets never reach tails or the log (S-8).
  (define secret-url "https://user:s3cret@example.com/x")
  (define redact-log (make-temporary-file "pm-redact~a.log"))
  (define redact-out (open-output-file redact-log #:exists 'truncate/replace))
  (define r
    (parameterize ([current-run-log-port redact-out])
      (run-ok echo-exe (list secret-url "token=abc123"))))
  (close-output-port redact-out)
  (for ([line (in-list (run-result-stdout-lines r))])
    (check-false (regexp-match? #rx"s3cret|abc123" line)))
  (define logged (file->string redact-log))
  (check-false (regexp-match? #rx"s3cret" logged))
  (check-false (regexp-match? #rx"abc123" logged))
  (check-true (regexp-match? #rx"<redacted>" logged))
  (delete-file redact-log)

  ;; Stress: >1MB on each stream, no hang, bounded tails, full log.
  (define big-log (make-temporary-file "pm-big~a.log"))
  (define big-log-port (open-output-file big-log #:exists 'truncate/replace))
  (define big-loop
    (string-append
     "pad=$(printf '%348s' ''); i=0; while [ $i -lt 3000 ];"
     " do echo \"out-$i$pad\";"
     " echo \"err-$i$pad\" >&2; i=$((i+1)); done"))
  (parameterize ([current-run-log-port big-log-port]
                 [current-captured-lines 20])
    (define big (run-ok sh-exe (list "-c" big-loop)))
    (close-output-port big-log-port)
    (check-equal? (run-result-exit big) 0)
    (check-true (<= (length (run-result-stdout-lines big)) 20))
    (check-true (<= (length (run-result-stderr-lines big)) 20))
    (check-true (> (file-size big-log) (* 1024 1024))))
  (delete-file big-log)

  ;; Temp dirs are unique per call without any clock (D-015 exception:
  ;; atomic exclusive create). Two parallel mktemp children print their
  ;; temp dir through a barrier fifo; the paths must differ.
  (define uniq-fifo (make-fifo! "uniq.fifo"))
  (define uniq-out (build-path barrier-dir "uniq.out"))
  (define mktemp-exe (find-executable-path "mktemp"))
  (define (spawn-printer)
    (process* (path->string sh-exe) "-c"
              (string-append "read x < " (path->string uniq-fifo)
                             "; mktemp -d -t pm-u.XXXXXX"
                             " >> " (path->string uniq-out))))
  (define printer-a (spawn-printer))
  (define printer-b (spawn-printer))
  (define uniq-held
    (open-output-file uniq-fifo #:exists 'update))
  (displayln "go" uniq-held)
  (displayln "go" uniq-held)
  (flush-output uniq-held)
  ;; Held open: closing before slow readers open would strand them; the
  ;; flush above matters too, since buffered bytes never reach readers.
  ((list-ref printer-a 4) 'wait)
  ((list-ref printer-b 4) 'wait)
  (close-output-port uniq-held)
  (define uniq-lines
    (string-split (string-trim (file->string uniq-out)) "\n"))
  (check-equal? (length uniq-lines) 2)
  (check-false (string=? (car uniq-lines) (cadr uniq-lines)))

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
                "EXIT:5")

  (delete-directory/files barrier-dir))
