#lang racket/base
;; apply.rkt -- the journaled plan interpreter (ENGINE.org
;; backends/apply.rkt, E-11).
;;
;; No special cases: every action in the plan (fetch through
;; set-current, in lowering order) runs through the given performer,
;; bracketed by journal start/end records under the plan's input
;; hash. A step whose recorded end hash still matches is skipped, so
;; a killed run resumes exactly where it stopped; anything else
;; re-runs. #:cancel raises kind 'cancelled between steps, never
;; mid-step. Locks live in jobs, not here: a same-process file lock
;; would hang the shared test runner (P-04). Manifests are E-14's
;; job, not this module's. The fake backend is just a performer
;; (fake-perform! records, nothing else); the real one is E-12's.

(require racket/contract/base
         racket/file
         racket/list
         "journal.rkt"
         "../core/errors.rkt"
         "../core/plan.rkt")

(provide
 (contract-out
  ;; plan string performer -> void, journaled run, resume by hash
  [apply-plan (->* (plan? string? (-> action? void?)
                          #:state path-string?
                          #:package string?
                          #:slot string?)
                   (#:cancel (or/c evt? #f))
                   void?)]))

;; action -> string, stable kind label for journal step names. Index
;; plus kind names the step; plans lower deterministically, so the
;; name is stable across the runs that resume each other.
(define (action-kind a)
  (cond [(fetch-action? a) "fetch"]
        [(extract-action? a) "extract"]
        [(run-step-action? a) "run-step"]
        [(install-file-action? a) "install-file"]
        [(write-file-action? a) "write-file"]
        [(symlink-action? a) "symlink"]
        [(remove-path-action? a) "remove-path"]
        [(export-action? a) "export"]
        [(check-action? a) "check"]
        [(mark-incomplete-action? a) "mark-incomplete"]
        [(clear-incomplete-action? a) "clear-incomplete"]
        [(set-current-action? a) "set-current"]
        [else (raise-pm-error 'internal 'apply-plan "not an action"
                              #:fields `(("value" . ,(format "~s" a))))]))

;; plan string performer -> void, one journaled pass over the plan
(define (apply-plan p input-hash performer
                    #:state state
                    #:package package
                    #:slot slot
                    #:cancel [cancel #f])
  (define actions (plan-actions p))
  (for ([a (in-list actions)] [i (in-range (length actions))])
    (define step (format "step-~a-~a" i (action-kind a)))
    (when (and cancel (sync/timeout 0 cancel))
      (raise-pm-error 'cancelled 'apply-plan "cancelled between steps"
                      #:fields `(("step" . ,step))))
    (unless (journal-step-done? state package slot step input-hash)
      (journal-record-start! state package slot step input-hash)
      (performer a)
      (journal-record-end! state package slot step input-hash))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           "fake.rkt"
           "local.rkt"
           "../core/errors.rkt"
           "../core/plan.rkt")

  ;; All fixtures are synthetic (T-10): plans over fake actions, one
  ;; temp state dir, package names isolating the scenarios. The fake
  ;; performer spawns nothing and touches no prefix.
  (define state-root (build-path (find-system-path 'temp-dir)
                                 "pm-apply-test"))
  (when (directory-exists? state-root)
    (delete-directory/files state-root))
  (make-directory* state-root)
  (define state (path->string state-root))

  ;; A green run performs every action in order and journals each end.
  (define green-plan
    (list->plan
     (list (mark-incomplete-action "/tmp/pm-apply-x/ver")
           (run-step-action "make" '("make" "all") "/tmp/pm-apply-x")
           (write-file-action "/tmp/pm-apply-x/out.txt" "x")
           (clear-incomplete-action "/tmp/pm-apply-x/ver"))))
  (define green-box (box '()))
  (parameterize ([current-fake-log green-box])
    (apply-plan green-plan "h1" fake-perform!
                #:state state #:package "pkg-green" #:slot "default"))
  (check-equal? (length (unbox green-box)) 4)
  (check-true (mark-incomplete-action? (last (unbox green-box))))
  (check-equal? (length (journal-completions state "pkg-green" "default"))
                4)

  ;; A failing build stops the run: earlier steps are done, the failed
  ;; step holds a start without an end, nothing after it ran.
  (define boom-performer
    (lambda (a)
      (if (run-step-action? a)
          (raise-pm-error 'build 'boom "simulated failing build"
                          #:fields `(("step" . "run-step")))
          (fake-perform! a))))
  (define fail-plan
    (list->plan
     (list (mark-incomplete-action "/tmp/pm-apply-x/ver")
           (write-file-action "/tmp/pm-apply-x/a.txt" "a")
           (run-step-action "boom" '("boom") "/tmp/pm-apply-x")
           (write-file-action "/tmp/pm-apply-x/b.txt" "b"))))
  (define run1-box (box '()))
  (define boom-err
    (parameterize ([current-fake-log run1-box])
      (with-handlers ([exn:fail:pm? (lambda (e) e)])
        (apply-plan fail-plan "h9" boom-performer
                    #:state state #:package "pkg-fail" #:slot "default")
        'no-error)))
  (check-pred build-error? boom-err)
  (check-equal? (length (unbox run1-box)) 2)
  (check-true (journal-step-done? state "pkg-fail" "default"
                                  "step-0-mark-incomplete" "h9"))
  (check-true (journal-step-done? state "pkg-fail" "default"
                                  "step-1-write-file" "h9"))
  (check-false (journal-step-done? state "pkg-fail" "default"
                                   "step-2-run-step" "h9"))

  ;; Resume re-runs only from the failed step: completed steps skip.
  (define run2-box (box '()))
  (parameterize ([current-fake-log run2-box])
    (apply-plan fail-plan "h9" fake-perform!
                #:state state #:package "pkg-fail" #:slot "default"))
  (check-equal? (length (unbox run2-box)) 2)
  (check-true (run-step-action? (last (unbox run2-box))))
  (check-true (journal-step-done? state "pkg-fail" "default"
                                  "step-2-run-step" "h9"))

  ;; A changed input hash reruns everything, skipping nothing.
  (define run3-box (box '()))
  (parameterize ([current-fake-log run3-box])
    (apply-plan fail-plan "hOTHER" fake-perform!
                #:state state #:package "pkg-fail" #:slot "default"))
  (check-equal? (length (unbox run3-box)) 4)

  ;; Cancel stops between steps: nothing performed, nothing journaled.
  (define cancel-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (parameterize ([current-fake-log (box '())])
        (apply-plan green-plan "h1" fake-perform!
                    #:state state #:package "pkg-cancel" #:slot "default"
                    #:cancel always-evt))
      'no-error))
  (check-pred cancelled-error? cancel-err)
  (check-equal? (journal-completions state "pkg-cancel" "default") '())

  ;; Cancel keeps the marker: the performer posts right after the
  ;; real mark step, so the peek-evt fires from the next step on. The
  ;; interrupted dir stays marked and the step after it never ran.
  ;; Deterministic: everything happens on one thread, no timers, no
  ;; sleeps, post never blocks and peek never waits.
  (define cancel-sem (make-semaphore 0))
  (define cancel-box (box '()))
  (define cancel-performer
    (lambda (a)
      (cond [(mark-incomplete-action? a)
             (local-perform! (list->plan (list a)))
             (fake-perform! a)
             (semaphore-post cancel-sem)]
            [else (fake-perform! a)])))
  (define cancel-ver (build-path state-root "cancel-ver"))
  (define cancel-plan
    (list->plan
     (list (mark-incomplete-action (path->string cancel-ver))
           (write-file-action (path->string (build-path cancel-ver "w.txt")) "w")
           (clear-incomplete-action (path->string cancel-ver)))))
  (define cancel2-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (parameterize ([current-fake-log cancel-box])
        (apply-plan cancel-plan "hc" cancel-performer
                    #:state state #:package "pkg-cancel2" #:slot "default"
                    #:cancel (semaphore-peek-evt cancel-sem)))
      'no-error))
  (check-pred cancelled-error? cancel2-err)
  (check-true (file-exists? (build-path cancel-ver ".pm-incomplete")))
  (check-true (journal-step-done? state "pkg-cancel2" "default"
                                  "step-0-mark-incomplete" "hc"))
  (check-false (journal-step-done? state "pkg-cancel2" "default"
                                   "step-1-write-file" "hc"))

  ;; An empty plan is void, never an error.
  (check-not-exn
   (lambda ()
     (apply-plan (list->plan '()) "h" fake-perform!
                 #:state state #:package "pkg-empty" #:slot "default")))
  (delete-directory/files state-root))
