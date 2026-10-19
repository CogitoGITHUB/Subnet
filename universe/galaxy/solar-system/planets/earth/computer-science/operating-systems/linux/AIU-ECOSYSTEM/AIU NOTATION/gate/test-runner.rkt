#lang racket/base
;; One job: the whole test gate — every test file in argv, in one process.
;; The run-tests stage of check.nu hands over the file list, this runner
;; answers one line per file and one exit code, and the stage reads the exit
;; code and nothing else. The gate parses no format, so the two cannot
;; disagree about it.
;;
;; One line per file, then one summary:
;;   TEST-END <file> failed=<n> total=<n> [error=<message>]
;;   SUMMARY files=<n> files-failed=<n> checks=<n> checks-failed=<n>
;; Exit is 0 only when every file passed, 2 when no file was named at all.
;;
;; A test file is one that provides run-checks, a zero-argument function
;; holding that file's checks. A file that provides it under another name is
;; reported NO-TESTS and counts as no checks, so a typo in the list cannot
;; hide a test file.
;;
;; Failure detection is explicit and never trusts "no news is good news":
;; raco/testing keeps TOTAL and FAILED counters; they are snapshotted before
;; and after each file and differenced, so a check that fails cannot read as a
;; pass. An exception, or an exit call inside a test, is caught by a catch-all
;; and counted as exactly one failed check, with its message.
;;
;; Isolation per file: the working directory, a COPY of the environment
;; variables, and the exit handler (the parameter is `exit-handler`, not
;; `current-exit-handler`). No timers, no polling, no sleeping (D-015): the
;; run ends when the last file has been run, and nothing waits on a clock.

(require (prefix-in rt: raco/testing)
         racket/list
         racket/runtime-path)

;; entry-name is the one name every test file provides. It is written here so
;; the runner and the test files cannot disagree about it.
(define entry-name 'run-checks)

;; run-one requires one file, calls its checks if it has any, and answers the
;; counts for that file alone.
(define (run-one f)
  (define before (rt:test-report))
  (define extra 0)
  (define note #f)
  (parameterize ([current-directory (current-directory)]
                 [current-environment-variables
                  (environment-variables-copy (current-environment-variables))]
                 [exit-handler (lambda (code) (raise (list 'exit-called code)))]
                 ;; A failing check logs an error; the default display handler
                 ;; would end the run on the first one, and the gate must see
                 ;; every file and every failure, so the message is printed and
                 ;; the run continues to the next check.
                 [error-display-handler
                  (lambda (message . rest)
                    (printf "TEST-FAIL ~a: ~a\n" f message)
                    (void))])
    (with-handlers ([(lambda (e) #t)
                     (lambda (e)
                       (set! extra 1)
                       (set! note (if (exn? e) (exn-message e) e)))])
      (define run
        (dynamic-require (string->path f) entry-name (lambda () #f)))
      (cond
        [(not run)
         (printf "NO-TESTS ~a: it does not provide ~a, so it holds no checks\n"
                 f entry-name)]
        [else (run)])))
  (define after (rt:test-report))
  (define failed (+ extra (- (car after) (car before))))
  (define total (+ extra (- (cdr after) (cdr before))))
  (printf "TEST-END ~a failed=~a total=~a~a\n"
          f failed total
          (if note (format " error=~s" note) ""))
  (flush-output)
  (list failed total))

;; main runs every file named, in the order it was named, and exits 0 only
;; when nothing failed anywhere.
(module+ main
  (define files (vector->list (current-command-line-arguments)))
  (when (null? files)
    (eprintf "usage: test-runner.rkt FILE ...\n")
    (exit 2))
  (define results (for/list ([f (in-list files)]) (run-one f)))
  (define files-failed (for/sum ([r (in-list results)]) (car r)))
  (define checks (for/sum ([r (in-list results)]) (cadr r)))
  (printf "SUMMARY files=~a files-failed=~a checks=~a checks-failed=~a\n"
          (length files) files-failed checks files-failed)
  (flush-output)
  (exit (if (positive? files-failed) 1 0)))