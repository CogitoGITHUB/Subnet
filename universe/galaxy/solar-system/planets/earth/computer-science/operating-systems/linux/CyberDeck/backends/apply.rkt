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
;; mid-step. One writer lock (E-12c): #:writer (id note) takes
;; core/vault-lock.rkt's try-only lock on the state dir first, failing
;; fast naming the holder; try-only never blocks, so it is safe even
;; in-process (P-04). Readers (journal queries) never lock; jobs keep
;; queue-time concerns. #:manifest + #:manifest-entry upsert the
;; declaration on success only: apply is the only manifest writer
;; (E-14; jobs.rkt:595 retires in Phase C, vault's use is fixtures).

(require racket/contract/base
         racket/file
         racket/list
         "journal.rkt"
         "manifest.rkt"
         "../core/errors.rkt"
         "../core/plan.rkt"
         "../core/vault-lock.rkt")

(provide
 (contract-out
  ;; plan string performer -> void, journaled run, resume by hash.
  ;; #:writer (id note) takes the try-only store writer lock first.
  [apply-plan (->* (plan? string? (-> action? void?)
                          #:state path-string?
                          #:package string?
                          #:slot string?)
                   (#:cancel (or/c evt? #f)
                    #:writer (or/c #f (list/c string? string?))
                    #:manifest (or/c path-string? #f)
                    #:manifest-entry (or/c manifest-entry? #f))
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

;; plan string performer -> void, one journaled pass over the plan,
;; under the writer lock when #:writer names one
(define (apply-plan p input-hash performer
                    #:state state
                    #:package package
                    #:slot slot
                    #:cancel [cancel #f]
                    #:writer [writer #f]
                    #:manifest [manifest #f]
                    #:manifest-entry [entry #f])
  (define (run)
    (define actions (plan-actions p))
    (for ([a (in-list actions)] [i (in-range (length actions))])
      (define step (format "step-~a-~a" i (action-kind a)))
      (when (and cancel (sync/timeout 0 cancel))
        (raise-pm-error 'cancelled 'apply-plan "cancelled between steps"
                        #:fields `(("step" . ,step))))
      (unless (journal-step-done? state package slot step input-hash)
        (journal-record-start! state package slot step input-hash)
        (performer a)
        (journal-record-end! state package slot step input-hash)))
    (when (and manifest entry)
      (manifest-write manifest
                      (manifest-upsert (manifest-read manifest) entry))))
  (if writer
      (call-with-vault-lock state (first writer) (second writer) run)
      (run)))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           "fake.rkt"
           "local.rkt"
           "manifest.rkt"
           "git.rkt"
           "run.rkt"
           "vault.rkt"
           "../core/git-url.rkt"
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

  ;; E-12: pkg-alpha end to end on real local fixtures. A synthetic
  ;; upstream repo (one script, one one-line makefile) goes through
  ;; vault fetch and export, a real store dir, the real marker and the
  ;; real current link, all driven by apply-plan over local-perform!.
  (define e12-home (build-path state-root "home"))
  (make-directory e12-home)
  (define (e12-git dir . args)
    (define res
      (run-command (git-executable-path) args
                   #:cwd (path->string dir)
                   #:kind 'fetch #:operation "e12-fixture"
                   #:env `(("GIT_AUTHOR_NAME" . "t")
                            ("GIT_AUTHOR_EMAIL" . "t@t")
                            ("GIT_COMMITTER_NAME" . "t")
                            ("GIT_COMMITTER_EMAIL" . "t@t")
                            ("HOME" . ,(path->string e12-home))
                            ("GIT_CONFIG_NOSYSTEM" . "1"))))
    (unless (zero? (run-result-exit res))
      (error 'e12-fixture "git failed: ~a" args))
    res)
  (define e12-up (build-path state-root "upstream"))
  (make-directory e12-up)
  (e12-git e12-up "init" "-b" "main" ".")
  (call-with-output-file (build-path e12-up "build.sh")
    (lambda (out) (display "#!/bin/sh\nprintf alpha > built.txt\n" out)))
  (call-with-output-file (build-path e12-up "makefile")
    (lambda (out) (display "all:\n\tsh build.sh\n" out)))
  (e12-git e12-up "add" "-A")
  (e12-git e12-up "commit" "-qm" "init")
  (define e12-vault-git (build-path state-root "e12vault" "vault.git"))
  (make-directory* (build-path state-root "e12vault"))
  (define e12-mirror (build-path state-root "e12mirror.git"))
  (define e12-staging (build-path state-root "e12staging"))
  (make-directory e12-staging)
  (define e12-ver (build-path state-root "store" "pkg-alpha" "default"
                              "1.0-e12e12e12e12"))
  (define e12-cur (build-path state-root "store" "pkg-alpha" "default"
                              "current"))
  (define e12-pin
    (parameterize ([current-allow-file-urls #t])
      (vault-init e12-vault-git)
      (vault-add-result-pin
       (vault-add e12-vault-git "pkg-alpha"
                  (string-append "file://" (path->string e12-up))))))
  (define e12-actions
    (list (fetch-action (string-append "file://" (path->string e12-up))
                        e12-pin
                        (path->string e12-mirror))
          (export-action 'pkg-alpha e12-pin (path->string e12-staging))
          (mark-incomplete-action (path->string e12-ver))
          (run-step-action "make" '("make" "-f" "makefile" "all")
                           (path->string e12-staging))
          (install-file-action
           (path->string (build-path e12-staging "built.txt"))
           (path->string (build-path e12-ver "built.txt"))
           #o644)
          (check-action '("sh" "-c" "test -f built.txt")
                        (path->string e12-ver))
          (clear-incomplete-action (path->string e12-ver))
          (set-current-action (path->string e12-ver)
                              (path->string e12-cur))))
  (define (e12-perform! a)
    (local-perform! (list->plan (list a))
                    #:prefix (path->string e12-ver)
                    #:commit e12-pin
                    #:vault (path->string e12-vault-git)))
  (parameterize ([current-allow-file-urls #t])
    (apply-plan (list->plan e12-actions) "e12" e12-perform!
                #:state state #:package "pkg-alpha" #:slot "default"))
  (check-equal? (file->string (build-path e12-ver "built.txt")) "alpha")
  (check-false (file-exists? (build-path e12-ver ".pm-incomplete")))
  (check-equal? (path->string (resolve-path e12-cur))
                (path->string e12-ver))
  (check-equal? (length (journal-completions state "pkg-alpha" "default"))
                8)
  (displayln "--- e12 store tree (ls -lR) ---")
  (define e12-ls
    (run-command (find-executable-path "ls")
                 (list "-lR" (path->string (build-path state-root "store")))
                 #:cwd state
                 #:kind 'build #:operation "e12-ls"))
  (for ([line (in-list (run-result-stdout-lines e12-ls))])
    (displayln line))
  (displayln "--- e12 journal ---")
  (displayln (file->string (journal-file state "pkg-alpha" "default")))

  ;; E-12c: one writer. The outer apply holds (id outer-apply) while
  ;; its performer runs the inner apply on the same state: the inner
  ;; try fails at once naming the holder, the outer completes unharmed
  ;; and the inner journal stays empty. Same thread, try-only, no wait.
  (define lock-box (box '()))
  (define inner-err-box (box #f))
  (define (lock-outer-performer a)
    (when (and (write-file-action? a) (not (unbox inner-err-box)))
      (set-box! inner-err-box
                 (with-handlers ([exn:fail:pm? (lambda (e) e)])
                   (apply-plan (list->plan (list (write-file-action
                                                  "/tmp/pm-apply-x/i.txt"
                                                  "i")))
                               "li" fake-perform!
                               #:state state #:package "pkg-inner"
                               #:slot "default"
                               #:writer (list "inner-apply"
                                              "second writer"))
                   'no-error)))
    (fake-perform! a))
  (define lock-plan
    (list->plan
     (list (write-file-action "/tmp/pm-apply-x/o1.txt" "o")
           (write-file-action "/tmp/pm-apply-x/o2.txt" "o"))))
  (parameterize ([current-fake-log lock-box])
    (apply-plan lock-plan "lw" lock-outer-performer
                #:state state #:package "pkg-lock" #:slot "default"
                #:writer (list "outer-apply" "first writer")))
  (define inner-err (unbox inner-err-box))
  (check-pred config-error? inner-err)
  (check-regexp-match #rx"outer-apply" (exn-message inner-err))
  (check-equal? (length (unbox lock-box)) 2)
  (check-equal? (length (journal-completions state "pkg-lock" "default"))
                2)
  (check-equal? (journal-completions state "pkg-inner" "default") '())

  ;; E-14: apply writes the manifest itself, on success only. The seed
  ;; entry survives (upsert, never overwrite); a failed run changes
  ;; nothing; without manifest args the run still succeeds journaled.
  (define mfile (build-path state-root "manifest.rktd"))
  (define seed-entry
    (manifest-entry "pkg-other" "https://example.org/o.git"
                    "refs/vault/pkg-other" 1 #f '() #f))
  (manifest-write mfile (list seed-entry))
  (define synth-entry
    (manifest-entry "pkg-synth" "https://example.org/s.git"
                    "refs/vault/pkg-synth" 2 #f '() #f))
  (define mplan
    (list->plan (list (write-file-action "/tmp/pm-apply-x/m.txt" "m"))))
  (define mbox (box '()))
  (parameterize ([current-fake-log mbox])
    (apply-plan mplan "hm" fake-perform!
                #:state state #:package "pkg-synth" #:slot "default"
                #:manifest mfile #:manifest-entry synth-entry))
  (check-equal? (manifest-read mfile) (list seed-entry synth-entry))
  ;; A failing run leaves the manifest exactly as it was.
  (define mfile2 (build-path state-root "manifest2.rktd"))
  (manifest-write mfile2 (list seed-entry))
  (with-handlers ([exn:fail:pm? (lambda (e) e)])
    (apply-plan mplan "hmx"
                (lambda (a) (raise-pm-error 'build 'm14 "boom"))
                #:state state #:package "pkg-mfail" #:slot "default"
                #:manifest mfile2 #:manifest-entry synth-entry))
  (check-equal? (manifest-read mfile2) (list seed-entry))
  ;; Without manifest args the run succeeds journaled, nothing to write.
  (parameterize ([current-fake-log (box '())])
    (apply-plan mplan "hm2" fake-perform!
                #:state state #:package "pkg-noman" #:slot "default"))
  (check-equal? (length (journal-completions state "pkg-noman" "default"))
                1)

  (delete-directory/files state-root))
