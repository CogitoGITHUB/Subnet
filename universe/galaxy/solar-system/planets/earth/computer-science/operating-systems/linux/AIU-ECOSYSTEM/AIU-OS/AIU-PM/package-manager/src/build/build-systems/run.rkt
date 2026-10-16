#lang racket/base
;; build-systems/run.rkt -- the run word: argv exactly as written, with
;; every $PREFIX expanded; the escape hatch for steps the vocabulary
;; cannot name. It builds the command only; build-executor.rkt spawns
;; it. The builder is named run-step-command so process/run.rkt's
;; run-command (the spawner itself) stays unambiguous.

(require racket/list
         "../build-env.rkt"
         "../../errors/error-type.rkt")

(provide
 ;; (listof any) path path string -> (values string (listof string) path)
 run-step-command)

;; (listof any) path path string -> (values string (listof string) path)
(define (run-step-command args work source prefix)
  (define raw-argv (as-strings (arg-val args '#:argv '())))
  (when (null? raw-argv)
    (raise-pm-error 'config 'execute-build-step
                    "run needs #:argv"
                    #:fields `(("step" . "run"))))
  (define dir (resolve-dir 'run (as-string (arg-val args '#:dir ".")
                                           ".")
                           work source))
  (define argv (map (lambda (a) (expand-prefix a prefix)) raw-argv))
  (values (first argv) (rest argv) dir))
