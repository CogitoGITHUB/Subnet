#lang racket/base
;; fake.rkt -- the test backend: records actions, performs nothing.
;; Core tests run plans through here to assert order and content
;; without touching the machine (T-8).

(require racket/contract/base
         "../core/errors.rkt"
         "../core/plan.rkt")

(provide
 current-fake-log
 (contract-out
  ;; action -> void, records ACTION newest-first in the current log
  [fake-perform! (-> action? void?)]
  ;; -> (listof action), recorded actions oldest-first
  [fake-log (-> (listof action?))]))

;; ---------------------------------------------------------------------------
;; Recording (no effects of any kind, only memory)

;; Parameter of (Boxof (Listof Action)), newest first; scope per test.
(define current-fake-log
  (make-parameter (box '())))

;; action -> void, records ACTION newest-first in the current log
;; Loud on misuse (P-7): contracts guard external callers, this guard
;; guards internal ones, and both agree on rejection.
(define (fake-perform! a)
  (unless (action? a)
    (raise-pm-error 'internal 'fake-perform! "not an action"
                    #:fields `(("value" . ,a))))
  (define log-box (current-fake-log))
  (set-box! log-box (cons a (unbox log-box))))

;; -> (listof action), recorded actions oldest-first
(define (fake-log)
  (reverse (unbox (current-fake-log))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           "../core/errors.rkt"
           "../core/plan.rkt")

  ;; Performed actions come back oldest-first with content intact.
  (parameterize ([current-fake-log (box '())])
    (define first-action
      (fetch-action "https://example.org/a.git"
                    (make-string 40 #\a) "/tmp/a"))
    (define second-action
      (run-step-action "build" '("make") "/tmp/a"))
    (fake-perform! first-action)
    (fake-perform! second-action)
    (check-equal? (fake-log) (list first-action second-action))
    (check-equal? (fetch-action-url (car (fake-log)))
                  "https://example.org/a.git"))

  ;; Logs are scoped: the outer box stays empty.
  (check-equal? (fake-log) '())

  ;; Misuse fails loudly with kind 'internal (P-7).
  (check-pred internal-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (fake-perform! "not-an-action")
                'no-error))

  ;; A full plan replays in order through the fake backend.
  (parameterize ([current-fake-log (box '())])
    (define demo-plan
      (list->plan
       (list (write-file-action "/pkg/pin" "abc")
             (symlink-action "/pkg/1.0" "/pkg/current")
             (remove-path-action "/tmp/stage"))))
    (for ([a (in-list (plan-actions demo-plan))])
      (fake-perform! a))
    (check-equal? (length (fake-log)) 3)
    (check-true (remove-path-action? (car (reverse (fake-log)))))))
