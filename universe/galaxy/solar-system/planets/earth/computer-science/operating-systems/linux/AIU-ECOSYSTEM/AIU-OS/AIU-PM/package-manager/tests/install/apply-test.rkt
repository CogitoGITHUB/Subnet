#lang racket/base
;; apply-test.rkt -- the moved-out test submodule of src/install/apply.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            racket/file
            racket/list
            racket/path
            racket/string
            "../../src/queue/journal.rkt"
            "../../src/install/local-perform.rkt"
            "../../src/store/manifest.rkt"
            "../../src/store/query.rkt"
            "../../src/git/vault.rkt"
            "../../src/errors/error-type.rkt"
            "../../src/machine/file-lock.rkt"
            "../../src/spec/plan.rkt"
            "../../src/machine/directories.rkt"
            "../../src/spec/spec.rkt"
            "../../src/spec/spec-read.rkt"
            "../../src/git/vault-lock.rkt"
            "../../src/narration/narration.rkt"
            "../../src/entry/version.rkt"
         "../../src/install/apply.rkt")

(module+ test
  (require rackunit
           racket/file
           racket/list
           racket/path
           racket/string
           "../../test-doubles/fake-git.rkt"
           "../../src/install/local-perform.rkt"
           "../../src/store/manifest.rkt"
           "../../src/git/git-repo.rkt"
           "../../src/process/run.rkt"
           "../../src/git/vault.rkt"
           "../../src/machine/cancel.rkt"
           "../../src/git/git-env.rkt"
           "../../src/errors/error-type.rkt"
           "../../src/spec/plan.rkt")

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

  ;; G-07: applying the same plan twice is a no-op. Every step is done
  ;; under h9, so the performer runs zero times and each action SKIPs.
  (define run2b-box (box '()))
  (parameterize ([current-fake-log run2b-box])
    (apply-plan fail-plan "h9" fake-perform!
                #:state state #:package "pkg-fail" #:slot "default"))
  (check-equal? (unbox run2b-box) '())

  ;; A changed input hash reruns everything, skipping nothing.
  (define run3-box (box '()))
  (parameterize ([current-fake-log run3-box])
    (apply-plan fail-plan "hOTHER" fake-perform!
                #:state state #:package "pkg-fail" #:slot "default"))
  (check-equal? (length (unbox run3-box)) 4)

  ;; G-08: the feed of an interrupted run shows the law. Inside one
  ;; verbose run, the failing apply emits FAIL and the resumed apply
  ;; emits SKIPs naming the hash, so a reader of the feed knows the run
  ;; resumed rather than restarted.
  (define feed-dir (build-path state "events-g08"))
  (make-directory* feed-dir)
  (define feed-text
    ;; The fake log is scoped, like every other test in this file. Without
    ;; the second binding the performer wrote into the module's DEFAULT
    ;; box, and every later file in the shared process can see it -- that
    ;; is what failed fake-git.rkt's "the outer box stays empty" assertion
    ;; when the whole suite ran in one process, and not when run alone.
    (parameterize ([verbose-screen? #f]
                   [current-fake-log (box '())])
      (begin-run! #:who 'test #:events-dir feed-dir)
      (with-handlers ([exn:fail:pm? void?])
        (apply-plan fail-plan "hG08" boom-performer
                    #:state state #:package "pkg-g08" #:slot "default"))
      (apply-plan fail-plan "hG08" fake-perform!
                  #:state state #:package "pkg-g08" #:slot "default")
      (end-run! "done")
      (for/fold ([acc ""])
                ([f (in-list (directory-list feed-dir))]
                 #:when (regexp-match? #rx"\\.jsonl$" (path->string f)))
        (string-append acc (file->string (build-path feed-dir f))))))
  (check-true (regexp-match? #rx"FAIL" feed-text))
  (check-true (regexp-match? #rx"SKIP" feed-text))
  (check-true (regexp-match? #rx"hG08" feed-text))

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
      (spawn-and-wait (git-executable-path) args
                   #:cwd (path->string dir)
                   #:kind 'fetch #:operation "e12-fixture"
                   #:env `(("GIT_AUTHOR_NAME" . "t")
                            ("GIT_AUTHOR_EMAIL" . "t@t")
                            ("GIT_COMMITTER_NAME" . "t")
                            ("GIT_COMMITTER_EMAIL" . "t@t")
                            ("HOME" . ,(path->string e12-home))
                            ("GIT_CONFIG_NOSYSTEM" . "1"))))
    (unless (zero? (result-exit res))
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
  ;; These dumps went to stdout, which the one-printer rule forbids: the
  ;; gate's text lint does not scan test submodules, so it passed while
  ;; breaking the law. They are narrated instead, which keeps the
  ;; diagnostic AND puts it where a reader looks. `note` is the INFO verb.
  ;; ONE event, not one per line. Narrating every line of an ls -lR
  ;; tree means one flushed write per line, and this suite runs on proot
  ;; where a flush costs about as much as the git spawns. Doing it that
  ;; way took the file from 155s to over 22 minutes and it was killed.
  ;; The count is the diagnostic; the assertions above already check the
  ;; journal, and the tree is checked by the install assertions.
  (define e12-ls
    (spawn-and-wait (find-executable-path "ls")
                 (list "-lR" (path->string (build-path state-root "store")))
                 #:cwd state
                 #:kind 'build #:operation "e12-ls"))
  (note 'e12 (format "store tree: ~a line(s) from ls -lR, exit ~a"
                     (length (result-stdout-lines e12-ls))
                     (result-exit e12-ls)))

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

  ;; --- pm-apply end to end on synthetic git fixtures (D-040) ---
  ;; Two local repos, beta depending on alpha. No network, no real
  ;; packages; the vault, state, prefix and manifest all live under
  ;; one temp root that is deleted at the end.
  ;;
  ;; --- why every case below narrates (D-041) ---
  ;; This block once went 41 minutes with no output at all: parked in
  ;; the runtime poll with 100+ leaked pipe fds, no child, no write, no
  ;; event. A silent region and a hang look identical from outside, and
  ;; "the last line printed" was the only thing anyone had. So every
  ;; case boundary, and every cleanup, now says what it is about to do,
  ;; and every boundary counts the fds and threads it inherited. The
  ;; census is the cheap half: run.rkt leaks three pipe fds per
  ;; subprocess call (proved: 120 calls move /proc/self/fd by exactly
  ;; 360, and a GC reclaims none of them), so a rising number here is
  ;; that leak, and a flat one is a flat one.
  (define (proc-count p)
    (with-handlers ([exn:fail? (lambda (_) "?")])
      (number->string (length (directory-list p)))))

  (define (e2e-census tag)
    (step 'e2e (string-append "census " tag)
          "a park in the next region has to be attributable, so what it inherits is counted first"
          #:how (format "fds=~a threads=~a"
                        (proc-count "/proc/self/fd")
                        (proc-count "/proc/self/task"))))

  ;; tag why thunk -> any: one narrated e2e case, start to finish.
  (define (e2e-case tag why thunk)
    (e2e-census (string-append "before " tag))
    (define result
      (wait-for 'e2e tag why #:how "the whole case, every spawn inside it" thunk))
    (e2e-census (string-append "after " tag))
    result)

  ;; tag dir -> void: a narrated cleanup. Deleting a fixture tree walks
  ;; real git objects and is a genuine wait, so it says which tree.
  (define (e2e-cleanup tag dir)
    (wait-for 'e2e tag
              "a fixture tree left behind is a tree the next run inherits"
              #:how (format "remove ~a" dir)
              (lambda ()
                (when (directory-exists? dir)
                  (delete-directory/files dir))
                (void))))

  (define e2e-root
    (build-path (find-system-path 'temp-dir) "pm-apply-e2e"))
  (e2e-cleanup "e2e-root-stale" e2e-root)
  (make-directory* e2e-root)
  (e2e-census "after e2e-root reset")
  (define e2e-home (build-path e2e-root "home"))
  (make-directory e2e-home)
  (define (e2e-git dir . args)
    (define res
      (spawn-and-wait (git-executable-path) args
                   #:cwd (path->string dir)
                   #:kind 'fetch #:operation "apply-e2e-fixture"
                   #:env (list (cons "GIT_AUTHOR_NAME" "t")
                               (cons "GIT_AUTHOR_EMAIL" "t@t")
                               (cons "GIT_COMMITTER_NAME" "t")
                               (cons "GIT_COMMITTER_EMAIL" "t@t")
                               (cons "HOME" (path->string e2e-home))
                               (cons "GIT_CONFIG_NOSYSTEM" "1"))))
    (unless (zero? (result-exit res))
      (error 'apply-e2e "git failed: ~a" args))
    res)
  (define (e2e-upstream name)
    (define d (build-path e2e-root name))
    (make-directory d)
    (e2e-git d "init" "-b" "main" ".")
    (call-with-output-file (build-path d "f.txt")
      (lambda (out)
        (displayln "F" out)))
    (e2e-git d "add" "-A")
    (e2e-git d "commit" "-qm" "init")
    ;; ONE list, not two values. A narration wrapper (wait-for, like
  ;; with-op) keeps only the first of a thunk's values, so returning a
  ;; pair and destructuring afterwards silently lost the pin. A list
  ;; survives narration intact, which is why this returns (list dir pin).
  (list d
        (car (result-stdout-lines
               (e2e-git d "rev-parse" "HEAD")))))
  ;; The fixture repos are made with four git spawns each. Narrated as one
  ;; case so a park in a fixture git call is attributable too.
  (define e2e-up-a-list
    (e2e-case "fixture up-a"
              "no pin exists until the upstream repo has a commit to point at"
              (lambda () (e2e-upstream "up-a"))))
  (define e2e-up-a (car e2e-up-a-list))
  (define e2e-pin-a (cadr e2e-up-a-list))
  (define e2e-up-b-list
    (e2e-case "fixture up-b"
              "no pin exists until the upstream repo has a commit to point at"
              (lambda () (e2e-upstream "up-b"))))
  (define e2e-up-b (car e2e-up-b-list))
  (define e2e-pin-b (cadr e2e-up-b-list))
  (define e2e-specs (build-path e2e-root "specs"))
  (make-directory e2e-specs)
  ;; REWRITES the file: case (e) bumps pkg-alpha's version in this same
  ;; specs dir, which is what "a changed input hash" means. Without the
  ;; truncate/replace the rewrite raised "file exists" and case (e) never
  ;; ran at all.
  (define (e2e-write-spec dir name ver deps pin up prog extra-install)
    (call-with-output-file (build-path dir (string-append name ".rktd"))
      (lambda (out)
        (displayln
          (string-append
            "(spec (format-version 2) (name " name ")"
            " (version \"" ver "\")"
            " (summary \"synthetic " name "\")"
            " (source (git \"" up "\" \"" pin "\"))"
            " (deps " deps ")"
            " (build (steps (run #:argv (\"sh\" \"-c\" \"cp f.txt g.txt\") #:dir \".\")))"
            " (install (prefix (bin \"g.txt\" \"bin/"
            prog
            "\")"
            extra-install "))"
            " (license mit)"
            " (homepage \"https://example.invalid/\"))")
          out))
      #:exists 'truncate/replace))
  (e2e-write-spec e2e-specs "pkg-alpha" "1.0.0" "()" e2e-pin-a
                  (string-append "file://" (path->string e2e-up-a))
                  "prog" "")
  (e2e-write-spec e2e-specs "pkg-beta" "1.0.0" "((pkg-alpha \"1.0.0\"))"
                  e2e-pin-b
                  (string-append "file://" (path->string e2e-up-b))
                  "beta-prog" "")
  (define e2e-state (path->string (build-path e2e-root "state")))
  (define e2e-prefix (path->string (build-path e2e-root "prefix")))
  (define e2e-vault (path->string (build-path e2e-root "vault.git")))
  (define e2e-manifest (path->string (build-path e2e-state "manifest.rktd")))
  ;; Simple on purpose. pm-apply answers ONE value (the rows), so the
  ;; narration wraps that value and there is no multi-value plumbing to
  ;; get wrong. An earlier version routed the result through a box and
  ;; call-with-values to survive a wrapper that keeps only the first
  ;; value; that was defending against a problem this call site does not
  ;; have, and the box is what broke it.
  ;;
  ;; The apply is INSIDE the narration, not before it: an earlier version
  ;; computed `rows` first and passed the finished list to e2e-case, so
  ;; every live case emitted its WAIT only after the work was over -- the
  ;; (c) wait read +0.001s over a forty-second apply, and a park in the
  ;; apply left the previous case's WAIT-DONE as the last word. A case that
  ;; narrates after the thing it describes is the same silence D-041 forbids.
  (define (e2e-live #:state state #:manifest manifest #:prefix prefix
                    #:case tag)
    (e2e-case tag
              "the installed tree is not inspectable until this apply has returned"
              (lambda ()
                (parameterize ([current-allow-file-urls #t])
                  (pm-apply (path->string e2e-specs)
                            #:state state
                            #:manifest manifest
                            #:prefix prefix
                            #:vault e2e-vault)))))
  ;; (a) dry run prints the plan and touches nothing.
  (define dry-plans
    (e2e-case "(a) dry-run"
              "nothing later here is meaningful unless the dry run renders and changes nothing"
              (lambda ()
                (parameterize ([current-allow-file-urls #t])
                  (pm-apply-dry (path->string e2e-specs))))))
  (check-equal? (map first dry-plans) '("pkg-alpha" "pkg-beta"))
  (check-true (andmap (lambda (p) (> (string-length (second p)) 0))
                      dry-plans))
  (check-false (directory-exists? (build-path e2e-state "store")))
  ;; (b) live run installs in resolve order with modes, links, journal.
  (define live-results
    (e2e-live #:state e2e-state #:manifest e2e-manifest #:prefix e2e-prefix
              #:case "(b) live install"))
  (check-equal? (map first live-results) '("pkg-alpha" "pkg-beta"))
  (check-equal? (map second live-results) '(applied applied))
  (define (e2e-installed prefix name prog)
    (check-true (link-exists? (build-path prefix name "current")))
    (define cur (resolve-path (build-path prefix name "current")))
    (check-equal? (file->string (build-path cur "bin" prog)) "F\n")
    cur)
  (e2e-installed e2e-prefix "pkg-alpha" "prog")
  (e2e-installed e2e-prefix "pkg-beta" "beta-prog")
  (define mans
    (wait-for 'e2e "(b) manifest-read"
              "the declared entries are only known once the manifest has been read back"
              #:how (format "read ~a" e2e-manifest)
              (lambda ()
                (parameterize ([current-allow-file-urls #t])
                  (manifest-read e2e-manifest)))))
  (check-equal? (sort (map manifest-entry-name mans) string<?)
                '("pkg-alpha" "pkg-beta"))
  ;; (c) second run is a pure SKIP no-op with every reason listed.
  (define rerun-results
    (e2e-live #:state e2e-state #:manifest e2e-manifest #:prefix e2e-prefix
              #:case "(c) rerun is a pure skip"))
  (check-equal? (map second rerun-results) '(skipped skipped))
  (for ([r (in-list rerun-results)])
    (check-true (> (length (third r)) 0))
    (for ([row (in-list (third r))])
      (check-equal? (second row) 'skipped)
      (check-regexp-match #rx"matches the journal" (fourth row))))
  ;; (d) cancel stops before anything is performed; rerun completes.
  (define e2e-state2 (path->string (build-path e2e-root "state2")))
  (define e2e-prefix2 (path->string (build-path e2e-root "prefix2")))
  (define e2e-manifest2
    (path->string (build-path e2e-state2 "manifest.rktd")))
  ;; A cancel that has ALREADY fired, which is the whole point of this case.
  ;; It is core/cancel.rkt's source, so it is the same primitive the CLI and
  ;; jobs use, and its trigger is a semaphore-post: that never blocks and
  ;; never waits for a reader.
  ;;
  ;; It was a bare (make-channel) with a channel-put instead, and THAT is the
  ;; hang this case used to cost. A channel made with no buffer is
  ;; SYNCHRONOUS: channel-put blocks until some other thread takes the value,
  ;; and nothing ever reads this one, so the put waited forever -- between the
  ;; (c) census and the (d) case, at no CPU, with flat fds and flat threads,
  ;; which is why it read as "not the leak" and went looking for a resource.
  ;; A channel here needs a reader that is never started, so the cancel
  ;; source that can already be posted is the semaphore one.
  (define-values (e2e-cancel-evt e2e-fire-cancel!) (make-cancel-source))
  (e2e-fire-cancel!)
  (define e2e-cancel-err
    (e2e-case "(d) cancel before any step"
              "nothing is installed until this apply has decided to stop"
              (lambda ()
                (with-handlers ([exn:fail:pm? (lambda (e) e)])
                  (parameterize ([current-allow-file-urls #t])
                    (pm-apply (path->string e2e-specs)
                              #:state e2e-state2
                              #:manifest e2e-manifest2
                              #:prefix e2e-prefix2
                              #:vault e2e-vault
                              #:cancel e2e-cancel-evt))
                  'no-error))))
  (check-pred cancelled-error? e2e-cancel-err)
  ;; "Nothing was performed" is proved by the store, the current link and
  ;; the journal. It is NOT proved by the absence of prefix/<package>:
  ;; pm-apply makes every package's prefix dir before it takes the writer
  ;; lock (its own "prefix-dirs" wait says why: a current link cannot land
  ;; without it), and the cancel only fires inside apply-plan, long after.
  ;; Asserting that dir's absence tested a precondition, not the law.
  (check-false (directory-exists? (build-path e2e-state2 "store")))
  (check-false (link-exists? (build-path e2e-prefix2 "pkg-alpha" "current")))
  (check-equal? (journal-completions e2e-state2 "pkg-alpha" "default") '())
  (define after-cancel-results
    (e2e-live #:state e2e-state2
              #:manifest e2e-manifest2
              #:prefix e2e-prefix2
              #:case "(d) rerun after cancel"))
  (check-equal? (map second after-cancel-results) '(applied applied))
  ;; (e) a changed input hash reruns the affected steps.
  (e2e-write-spec e2e-specs "pkg-alpha" "1.0.1" "()" e2e-pin-a
                  (string-append "file://" (path->string e2e-up-a))
                  "prog" "")
  (e2e-write-spec e2e-specs "pkg-beta" "1.0.0" "((pkg-alpha \"1.0.1\"))"
                  e2e-pin-b
                  (string-append "file://" (path->string e2e-up-b))
                  "beta-prog" "")
  (define bumped-results
    (e2e-live #:state e2e-state #:manifest e2e-manifest #:prefix e2e-prefix
              #:case "(e) changed input hash reruns"))
  (check-equal? (map second bumped-results) '(applied applied))
  ;; (f) a failing check leaves the marker and the old current alone.
  (define e2e-state3 (path->string (build-path e2e-root "state3")))
  (define e2e-prefix3 (path->string (build-path e2e-root "prefix3")))
  (define e2e-manifest3
    (path->string (build-path e2e-state3 "manifest.rktd")))
  (define e2e-specs-ok (build-path e2e-root "specs-ok"))
  (make-directory e2e-specs-ok)
  (e2e-write-spec e2e-specs-ok "pkg-gamma" "1.0.0" "()" e2e-pin-a
                  (string-append "file://" (path->string e2e-up-a))
                  "prog" "")
  (define (e2e-apply-gamma specs-dir tag)
    (e2e-case tag
              "gamma's store and current link are only inspectable once this apply has returned"
              (lambda ()
                (parameterize ([current-allow-file-urls #t])
                  (pm-apply (path->string specs-dir)
                            #:state e2e-state3
                            #:manifest e2e-manifest3
                            #:prefix e2e-prefix3
                            #:vault e2e-vault)))))
  (e2e-apply-gamma e2e-specs-ok "(f) gamma installs clean")
  (define good-current
    (resolve-path (build-path e2e-prefix3 "pkg-gamma" "current")))
  (define e2e-specs-bad (build-path e2e-root "specs-bad"))
  (make-directory e2e-specs-bad)
  (e2e-write-spec e2e-specs-bad "pkg-gamma" "1.0.1" "()" e2e-pin-a
                  (string-append "file://" (path->string e2e-up-a))
                  "prog" " (check \"sh\" \"-c\" \"exit 1\")")
  (define bad-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (e2e-apply-gamma e2e-specs-bad "(f) gamma fails its check")
      'no-error))
  (check-pred build-error? bad-err)
  (check-equal? (resolve-path (build-path e2e-prefix3 "pkg-gamma" "current"))
                good-current)
  (define bad-versioned
    (build-path e2e-state3 "store" "pkg-gamma" "default"))
  (define bad-gens (directory-list bad-versioned))
  (check-equal? (length bad-gens) 2)
  (define new-gen
    (for/first ([g (in-list bad-gens)]
                #:unless (equal? (path->string g)
                                 (path->string
                                   (file-name-from-path good-current))))
      g))
  (check-true
    (file-exists? (build-path bad-versioned new-gen ".pm-incomplete")))
  ;; (g) a second concurrent apply is refused naming the holder.
  (define busy-err
    (e2e-case "(g) second writer refused"
              "the refusal only means something once the inner apply has had its chance"
              (lambda ()
                (with-handlers ([exn:fail:pm? (lambda (e) e)])
                  (call-with-vault-lock e2e-state
                                        "holder"
                                        "test holds the lock"
                                        (lambda ()
                                          (e2e-live #:state e2e-state
                                                    #:manifest e2e-manifest
                                                    #:prefix e2e-prefix
                                                    #:case "(g) inner apply")))
                  'no-error))))
  (check-pred exn:fail:pm? busy-err)
  (check-regexp-match #rx"holder" (exn-message busy-err))
  ;; The two cleanups are narrated for the same reason the cases are: a
  ;; park in a delete-directory over a real git tree used to be
  ;; indistinguishable from a park in an apply. This tree also holds a
  ;; `current` symlink pointing back into itself, so the walk has more to
  ;; resolve than a plain tree does.
  (e2e-cleanup "(z) e2e-root teardown" e2e-root)
  (e2e-cleanup "(z) state-root teardown" state-root)
  )

