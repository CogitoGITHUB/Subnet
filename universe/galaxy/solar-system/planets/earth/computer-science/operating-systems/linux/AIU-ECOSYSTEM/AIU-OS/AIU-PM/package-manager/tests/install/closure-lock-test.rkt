#lang racket/base
;; closure-lock-test.rkt -- the tests for src/install/closure-lock.rkt,
;; plus the two apply-level laws it exists for.
;;
;; G-02: the lock covers the WHOLE CLOSURE an apply touches, a second
;; apply on the same install root is refused at once naming the holder
;; (never a hang), and two DIFFERENT install roots are two closures.
;; G-07: a re-run performs nothing and every SKIP states its reason --
;; which input hash, and which journal entry it was read from.
;;
;; Step 14 of TODO.org phase A put this body under package-manager/tests/
;; mirroring package-manager/src/ one area to one area, so the require
;; list below is the module's OWN list, redirected at src/, plus the
;; module itself: this body could already see everything it uses.

(require rackunit
   racket/contract/base
            racket/file
            racket/path
            racket/string
            "../../src/errors/error-type.rkt"
            "../../src/git/vault-lock.rkt"
         "../../src/narration/narration.rkt"
         "../../src/install/closure-lock.rkt")

(module+ test
  (require rackunit
           racket/file
           racket/list
           racket/path
           racket/string
           json
           "../../test-doubles/fake-git.rkt"
           "../../src/errors/error-type.rkt"
           "../../src/spec/plan.rkt"
           "../../src/queue/journal.rkt"
           "../../src/narration/narration.rkt"
           "../../src/git/vault-lock.rkt"
           "../../src/install/closure-lock.rkt"
           "../../src/install/apply.rkt")

  ;; All fixtures are synthetic (T-10) under one temp root: two install
  ;; roots, one state dir per apply, one events dir. Nothing reads the
  ;; real home, the real XDG dirs, or the network.
  (define test-root (make-temporary-directory "pm-closure~a"))
  (define install-root (path->string (build-path test-root "install-a")))
  (define other-root (path->string (build-path test-root "install-b")))

  ;; --- G-02: the lock file is INSIDE the install root, one per root ---
  ;; The unit is the install root. This is the assertion that says so:
  ;; the mechanism places its lock at a SIBLING of the root it is
  ;; handed, so handing it the install root itself put the lock in the
  ;; install root's PARENT, where a second install root would have
  ;; shared it and been refused for nothing.
  (define lock-a (closure-lock-file install-root))
  (define lock-b (closure-lock-file other-root))
  (check-pred path? lock-a)
  (check-true (string-prefix? (path->string lock-a) install-root))
  (check-true (string-prefix? (path->string lock-b) other-root))
  (check-false (equal? lock-a lock-b))

  ;; --- G-02: an interleave is refused naming the holder, not waited on
  ;; The inner attempt never runs and never blocks: it fails at once
  ;; with kind 'config, and the refusal names the holder's id, its note
  ;; and the closure they are holding. Two checks in one because both
  ;; are the law: a refusal that did not name the holder would send
  ;; the reader hunting, and a hang would never name it at all.
  (define inner-ran (box #f))
  (define interleave-error
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (call-with-closure-lock install-root "outer-apply" "first writer"
                              (lambda ()
                                (call-with-closure-lock
                                 install-root "inner-apply" "second writer"
                                 (lambda () (set-box! inner-ran 'ran)))))
      'no-error))
  (check-pred config-error? interleave-error)
  (check-false (unbox inner-ran))
  (check-regexp-match #rx"install closure busy" (exn-message interleave-error))
  (check-regexp-match #rx"outer-apply" (exn-message interleave-error))
  (check-regexp-match #rx"first writer" (exn-message interleave-error))
  ;; the waiting id and the scope both land, so the reader knows WHO is
  ;; in the way and WHAT is being kept out
  (check-regexp-match #rx"inner-apply" (exn-message interleave-error))
  (check-true (string-contains? (exn-message interleave-error) install-root))
  (check-true (string-contains? (exn-message interleave-error)
                                "every package's journalled steps"))

  ;; --- the refusal released cleanly: the next apply takes the closure
  ;; A refusal that left the lock held would turn one interleave into a
  ;; stuck install root, so the release is asserted, not assumed.
  (check-equal? (call-with-closure-lock install-root "after-refusal" "ok"
                                         (lambda () 'free))
                'free)

  ;; --- G-02: two install roots are two closures, not one shared lock
  ;; Holding one root while taking the other is the ordinary case of two
  ;; side-by-side installs; refusing it would be a false interleave.
  (check-equal?
   (call-with-closure-lock install-root "root-a" "a"
                           (lambda ()
                             (call-with-closure-lock other-root "root-b" "b"
                                                     (lambda () 'both-held))))
   'both-held)

  ;; --- G-07: a re-run performs nothing and every SKIP states a reason
  ;; The reasons are read out of the NARRATION FEED, not out of the
  ;; performer: what a skipped step tells the reader is what the feed
  ;; recorded, and a reason that exists only in a return value proves
  ;; nothing about what was said.
  (define state (build-path test-root "state"))
  (make-directory* state)
  (define state-s (path->string state))
  (define events-dir (build-path test-root "events"))
  (make-directory* events-dir)
  (define plan
    (list->plan
     (list (write-file-action "/pkg/one.txt" "one")
           (write-file-action "/pkg/two.txt" "two"))))
  (define (feed-text)
    (for/fold ([acc ""])
              ([f (in-list (directory-list events-dir))]
               #:when (regexp-match? #rx"\\.jsonl$" (path->string f)))
      (string-append acc (file->string (build-path events-dir f)))))
  (define (feed-events)
    (for/list ([l (in-list (string-split (feed-text) "\n"))]
               #:unless (string=? (string-trim l) ""))
      (read-json (open-input-string l))))
  (define first-log (box '()))
  (parameterize ([verbose-screen? #f]
                 [current-fake-log first-log])
    (begin-run! #:who 'test #:events-dir events-dir)
    (apply-plan plan "hG07" fake-perform!
                #:state state-s #:package "pkg-g07" #:slot "default")
    (end-run! "first apply"))
  (check-equal? (length (unbox first-log)) 2)
  ;; The second apply over the same plan and the same input hash.
  (define second-log (box '()))
  (parameterize ([verbose-screen? #f]
                 [current-fake-log second-log])
    (begin-run! #:who 'test #:events-dir events-dir)
    (apply-plan plan "hG07" fake-perform!
                #:state state-s #:package "pkg-g07" #:slot "default")
    (end-run! "second apply"))
  ;; Nothing was performed a second time: no re-verify, no re-apply.
  (check-equal? (unbox second-log) '())
  (check-equal? (length (journal-completions state-s "pkg-g07" "default"))
                2)
  ;; One SKIP per step, in step order, each naming its own step.
  (define skips
    (for/list ([e (in-list (feed-events))]
               #:when (equal? (hash-ref e 'kind) "SKIP"))
      e))
  (check-equal? (map (lambda (e) (hash-ref e 'what)) skips)
                '("step-0-write-file" "step-1-write-file"))
  (for ([e (in-list skips)])
    (define why (hash-ref e 'why))
    ;; which hash landed ...
    (check-true (string-contains? why "hG07"))
    ;; ... which journal entry says so ...
    (check-true (string-contains? why "journal/pkg-g07/default.jsonl"))
    ;; ... and which step it was, so the reason matches the row it
    ;; belongs to rather than floating free of it.
    (check-true (string-contains? why (hash-ref e 'what))))

  ;; --- G-02 at the apply level: an interleave changes nothing
  ;; A held closure must refuse an apply BEFORE its first step, so the
  ;; refusal and the empty journal together are the proof: had the
  ;; refusal come later, the journal would already hold a start record.
  (define blocked-state (build-path test-root "blocked-state"))
  (make-directory* blocked-state)
  (define blocked-s (path->string blocked-state))
  (define blocked-log (box '()))
  (define blocked-error
    (parameterize ([verbose-screen? #f]
                   [current-fake-log blocked-log])
      (with-handlers ([exn:fail:pm? (lambda (e) e)])
        (call-with-closure-lock
         blocked-s "holding-apply" "holds the closure"
         (lambda ()
           (apply-plan (list->plan (list (write-file-action "/pkg/x.txt" "x")))
                       "hB" fake-perform!
                       #:state blocked-s #:package "pkg-blocked"
                       #:slot "default"
                       #:writer '("blocked-apply" "tries to interleave"))))
        'no-error)))
  (check-pred config-error? blocked-error)
  (check-regexp-match #rx"holding-apply" (exn-message blocked-error))
  (check-equal? (unbox blocked-log) '())
  (check-equal? (journal-completions blocked-s "pkg-blocked" "default") '())

  (delete-directory/files test-root))
