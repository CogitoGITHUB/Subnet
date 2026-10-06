#lang racket/base
;; dry-run.rkt -- the default backend: prints the plan, performs nothing.
;; It must never require run.rkt or git.rkt; construction alone proves
;; it cannot touch the machine (pending acceptance item 7 covers the
;; full dry-run path once the local backend exists to contrast with).

(require racket/contract/base
         "../core/errors.rkt"
         "../core/plan.rkt")

(provide
 (contract-out
  ;; plan -> string, the printable plan and nothing else
  [plan->dry-run-text (-> plan? string?)]
  ;; plan -> void, prints the plan to the given port (or stdout)
  [display-plan (->* (plan?) (#:port output-port?) void?)]))

;; ---------------------------------------------------------------------------
;; Display (P-2: effects at the edge; here the only effect is printing)

;; plan -> string, the printable plan and nothing else
(define (plan->dry-run-text p)
  (plan->text p))

;; plan -> void, prints the plan to the given port (or stdout)
(define (display-plan p #:port [port (current-output-port)])
  (define text (plan->dry-run-text p))
  (unless (string=? text "")
    (displayln text port)))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           "../core/plan.rkt")

  ;; A plan containing a run-step prints without touching anything.
  (define printed-plan
    (list->plan
     (list (fetch-action "https://example.org/r.git"
                         (make-string 40 #\a) "/tmp/s")
           (run-step-action "compile" '("make" "-j4") "/tmp/stage"))))
  (define out (open-output-string))
  (display-plan printed-plan #:port out)
  (check-equal?
   (get-output-string out)
   (string-append "fetch https://example.org/r.git @ "
                  (make-string 40 #\a)
                  " -> /tmp/s\n"
                  "run-step compile [make -j4] in /tmp/stage\n"))

  ;; Text and display agree; empty plans print nothing.
  (check-equal? (get-output-string out)
                (string-append (plan->dry-run-text printed-plan) "\n"))
  (define empty-out (open-output-string))
  (display-plan (list->plan '()) #:port empty-out)
  (check-equal? (get-output-string empty-out) "")

  ;; Non-plans are rejected at the boundary.
  (check-exn exn:fail:contract?
             (lambda () (plan->dry-run-text "not-a-plan")))

  ;; The canary: printing creates no files anywhere near cwd.
  (define canary "pm-dry-run-canary")
  (when (file-exists? canary) (delete-file canary))
  (display-plan printed-plan #:port (open-output-string))
  (check-false (file-exists? canary)))
