#lang racket/base
;; run.rkt -- one place that spawns subprocesses (F-2): argv lists only,
;; explicit cwd, allowlisted env, timeouts, concurrent drain, whole-tree kill.

(require racket/contract/base
         racket/system
         racket/string
         "../core/errors.rkt")

(provide (struct-out run-result)
 (contract-out
  ;; Lines of tail output kept per stream; default 20.
  [current-captured-lines (parameter/c exact-positive-integer?)]
  ;; When set, full output streams here line by line (bounded memory).
  [current-run-log-port (parameter/c (or/c #f output-port?))]
  ;; exe argv -> result; timeout raises KIND naming operation and limit (E-14)
  [run-command (->* (path-string? (listof string?)
                     #:cwd path-string?
                     #:kind pm-kind/c
                     #:timeout exact-positive-integer?
                     #:operation string?)
                    (#:env (listof (cons/c string? string?)))
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
;; Concurrent drain (threads): bounded tail buffer, full text to the log port.

;; input-port (or #f output-port) box exact-int -> thread
(define (drain-thread in log-port lines-box limit)
  (thread
   (lambda ()
     (let loop ()
       (define line (read-line in 'any))
       (unless (eof-object? line)
         (define clean (redact-credentials line))
         (when log-port
           (displayln clean log-port))
         (set-box! lines-box
                   (let ((b (cons clean (unbox lines-box))))
                     (if (> (length b) limit)
                         (reverse (cdr (reverse b)))
                         b)))
         (loop))))))

;; ---------------------------------------------------------------------------
;; Spawning with whole-tree kill on timeout.
;; Racket process groups are unavailable under proot
;; (subprocess-group-enabled -> #f, probed 2026-10-06), so children launch
;; via setsid (own process group) and die via pkill -g on timeout.
;; make-environment-variables also segfaults under this proot (probed
;; 2026-10-06), so the allowlist is enforced with env -i instead. Values
;; passed here are visible in ps output; never pass secrets via #:env.

;; -> path, helper binary or kind 'config when missing
(define (find-helper name)
  (or (find-executable-path name)
      (raise-pm-error 'config 'run-command "helper executable missing"
                      #:fields `(("helper" . ,name)))))

;; path-string (listof string) -> run-result
(define (run-command exe argv
                     #:cwd cwd
                     #:kind kind
                     #:timeout timeout
                     #:operation operation
                     #:env [extras '()])
  (check-env-names extras)
  (define setsid-exe (find-helper "setsid"))
  (define pkill-exe (find-helper "pkill"))
  (define env-exe (find-helper "env"))
  (unless (file-exists? exe)
    (raise-pm-error 'config 'run-command "executable not found"
                    #:fields `(("exe" . ,exe))))
  (define limit (current-captured-lines))
  (define log-port (current-run-log-port))
  (define out-box (box '()))
  (define err-box (box '()))
  (define exe-string (if (path? exe) (path->string exe) exe))
  (define r
    (parameterize ([current-directory cwd])
      (apply process* (path->string setsid-exe)
             (append (list (path->string env-exe) "-i")
                     (env-assignments extras)
                     (cons exe-string argv)))))
  (define out-port (list-ref r 0))
  (define in-port (list-ref r 1))
  (define pgid (list-ref r 2))
  (define err-port (list-ref r 3))
  (define ctl (list-ref r 4))
  (close-output-port in-port)
  (define out-drainer (drain-thread out-port log-port out-box limit))
  (define err-drainer (drain-thread err-port log-port err-box limit))
  (define waiter (thread (lambda () (ctl (quote wait)))))
  (define (finish)
    (thread-wait out-drainer)
    (thread-wait err-drainer)
    (close-input-port out-port)
    (close-input-port err-port)
    (when log-port (flush-output log-port))
    (run-result (ctl (quote exit-code))
                (reverse (unbox out-box))
                (reverse (unbox err-box))))
  (if (sync/timeout timeout (thread-dead-evt waiter))
      (begin (thread-wait waiter) (finish))
      (let ([k (process* (path->string pkill-exe) "-KILL" "-g" (number->string pgid))])
        ((list-ref k 4) (quote wait))
        (close-input-port (list-ref k 0))
        (close-output-port (list-ref k 1))
        (close-input-port (list-ref k 3))
        (thread-wait waiter)
        (finish)
        (raise-pm-error kind 'run-command "command timed out"
                        #:fields `(("operation" . ,operation)
                                   ("timeout-seconds" . ,(number->string timeout))
                                   ("command" . ,(string-join
                                                  (map (lambda (a)
                                                         (if (path? a)
                                                             (path->string a)
                                                             a))
                                                       (cons exe argv))
                                                  " ")))))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/string
           "../core/errors.rkt")

  (define sh-exe (find-executable-path "sh"))
  (define echo-exe (find-executable-path "echo"))
  (define ps-exe (find-executable-path "ps"))
  (define cwd (current-directory))

  (define (run-ok exe argv)
    (run-command exe argv
                 #:cwd cwd #:kind 'fetch #:timeout 60 #:operation "test"))

  ;; Basic success: exit code and split streams.
  (define basic (run-ok echo-exe '("hi")))
  (check-equal? (run-result-exit basic) 0)
  (check-equal? (run-result-stdout-lines basic) '("hi"))
  (check-equal? (run-result-stderr-lines basic) '())

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
                            #:cwd cwd #:kind 'fetch #:timeout 60
                            #:operation "test"
                            #:env '(("HAS SPACE" . "x")))))

  ;; Timeout names the operation and the limit.
  (define timeout-exn
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (run-command sh-exe '("-c" "sleep 30")
                   #:cwd cwd #:kind 'fetch #:timeout 2
                   #:operation "test-sleep")))
  (check-pred fetch-error? timeout-exn)
  (check-equal? (cdr (assoc "operation" (exn:fail:pm-fields timeout-exn)))
                "test-sleep")
  (check-equal? (cdr (assoc "timeout-seconds" (exn:fail:pm-fields timeout-exn)))
                "2")

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

  ;; Timeout kills the whole tree: script plus its sleeping child both die.
  (define kill-dir (make-temporary-directory "pm-kill~a"))
  (define kill-script (build-path kill-dir "sleeper.sh"))
  (call-with-output-file kill-script
    (lambda (port)
      (displayln "#!/bin/sh" port)
      (displayln "echo $$ > \"$1/pids\"" port)
      (displayln "sleep 60 & echo $! >> \"$1/pids\"" port)
      (displayln "sleep 60" port)))
  (file-or-directory-permissions kill-script #o755)
  (check-exn fetch-error?
             (lambda ()
               (run-command kill-script (list (path->string kill-dir))
                            #:cwd cwd #:kind 'fetch #:timeout 3
                            #:operation "test-kill")))
  (sleep 1)
  (define pids
    (map string-trim
         (string-split (file->string (build-path kill-dir "pids")) "\n"
                       #:trim? #f)))
  (define live
    (map string-trim
         (run-result-stdout-lines
          (run-ok ps-exe '("-eo" "pid=")))))
  (for ([p (in-list pids)]
        #:unless (string=? p ""))
    (check-false (if (member p live) #t #f) (format "survivor: ~a" p)))
  (delete-directory/files kill-dir))
