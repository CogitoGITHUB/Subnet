#lang racket/base

;; scripts/test-runner.rkt -- shared-process test runner (P-04 follow-up).
;;
;; raco test re-links libraries for every file, which costs about five
;; seconds each on this phone. Running the same files in ONE process and
;; ONE namespace makes files 2..n cost milliseconds. The logic here is the
;; one proved in /tmp/opencode/fr/drv.rkt; only the reporting is added.
;;
;; Failure detection is explicit and never trusts "no news is good news":
;;   - raco/testing keeps TOTAL and FAILED module counters, exposed as
;;     rt:test-report = (cons FAILED TOTAL). Snapshot before and after each
;;     file and diff, so a check that fails cannot read as a pass.
;;   - an exception or an exit call inside a test is caught by a catch-all
;;     handler and counted as exactly one failed test, with its message.
;; Isolation per file: cwd, a COPY of the environment, and exit-handler
;; (the parameter is `exit-handler`, not `current-exit-handler`). No
;; timers, no polling, no sleeping anywhere (D-015).

(require (prefix-in rt: raco/testing)
         racket/runtime-path
         racket/list)

;; path -> boolean, true when the file declares a "test" submodule.
;; Read from the source text, so answering costs nothing and loads
;; nothing. module-declared? was tried first and returned false for
;; every file here, so the text form is what is proved.
(define (has-test-submodule? f)
  (with-handlers ([exn? (lambda (_) #f)])
    (regexp-match? #rx"\\(module\\+ test" (open-input-file f))))

(define (now) (current-inexact-monotonic-milliseconds))

(define (run-one f)
  (printf "TEST-START ~a\n" f)
  (flush-output)
  (cond
    [(not (has-test-submodule? f))
     ;; never silently: a file with nothing to run is reported and counts
     ;; as a pass, so a typo in the list cannot hide a test file.
     (printf "NO-TESTS ~a\n" f)
     (printf "TEST-END ~a failed=0 total=0 ms=0\n" f)
     (flush-output)
     (list 0 0 0)]
    [else
     (define t0 (now))
     (define before (rt:test-report))
     (define extra 0)
     (define msg #f)
     (parameterize ([current-directory (current-directory)]
                    [current-environment-variables
                     (environment-variables-copy (current-environment-variables))]
                    [exit-handler (lambda (c) (raise (list 'exit-called c)))])
       (with-handlers ([(lambda (e) #t)
                        (lambda (e)
                          (set! extra 1)
                          (set! msg (if (exn? e) (exn-message e) e)))])
         (dynamic-require
          (list 'submod (list 'file (path->string (path->complete-path f))) 'test)
          #f)))
     (define after (rt:test-report))
     (define failed (+ extra (- (car after) (car before))))
     (define total (+ extra (- (cdr after) (cdr before))))
     (printf "TEST-END ~a failed=~a total=~a ms=~a~a\n"
             f failed total (round (- (now) t0))
             (if msg (format " error=~s" msg) ""))
     (flush-output)
     (list failed total (round (- (now) t0)))]))

(module+ main
  (define files (vector->list (current-command-line-arguments)))
  (when (null? files)
    (eprintf "usage: test-runner.rkt FILE ...\n")
    (exit 2))
  (define results (for/list ([f (in-list files)]) (run-one f)))
  (define n-failed (for/sum ([r (in-list results)]) (car r)))
  (define n-total (for/sum ([r (in-list results)]) (cadr r)))
  ;; SLOWEST, sorted here in Racket so Nu never has to parse anything.
  (define timed
    (for/list ([f (in-list files)] [r (in-list results)])
      (list (caddr r) f)))
  (printf "SLOWEST:\n")
  (define ranked (sort timed (lambda (a b) (> (car a) (car b)))))
  (define top (if (> (length ranked) 10) (take ranked 10) ranked))
  (for ([row (in-list top)])
    (printf "  ~a ~a\n" (car row) (cadr row)))
  (printf "SUMMARY files=~a failed=~a total=~a\n"
          (length files) n-failed n-total)
  (flush-output)
  (exit (if (positive? n-failed) 1 0)))
