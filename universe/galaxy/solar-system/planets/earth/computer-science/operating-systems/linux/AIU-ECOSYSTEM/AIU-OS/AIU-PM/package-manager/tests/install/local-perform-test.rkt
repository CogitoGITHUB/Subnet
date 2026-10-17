#lang racket/base
;; local-perform-test.rkt -- the moved-out test submodule of src/install/local-perform.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            racket/file
            racket/path
            racket/string
            "../../src/process/run.rkt"
            "../../src/git/git-repo.rkt"
            "../../src/store/store.rkt"
            "../../src/git/vault.rkt"
            "../../src/errors/error-type.rkt"
            "../../src/security/security.rkt"
            "../../src/spec/plan.rkt"
            "../../src/narration/narration.rkt"
         "../../src/install/local-perform.rkt")

(module+ test
  (require rackunit
           racket/file
           "../../src/git/git-repo.rkt"
           "../../src/process/run.rkt"
           "../../src/store/store.rkt"
           "../../src/git/vault.rkt"
           "../../src/git/git-env.rkt"
           "../../src/errors/error-type.rkt"
           "../../src/spec/plan.rkt")

  ;; Fresh prefix plus vault roots per test group.
  (define test-root (make-temporary-directory "pm-local~a"))
  (define test-prefix (build-path test-root "prefix"))
  (make-directory test-prefix)
  (define test-vault (build-path test-root "vault"))
  (make-directory test-vault)
  (define test-home (build-path test-root "home"))
  (make-directory test-home)


  ;; Write plus install plus link plus remove, all inside the prefix.
  (local-perform!
   (list->plan
    (list (write-file-action (path->string
                              (build-path test-prefix "stamp.txt"))
                             "pinned-here")
          (install-file-action
           (path->string (build-path test-prefix "stamp.txt"))
           (path->string (build-path test-prefix "deep" "copied.txt"))
           #o644)
          (symlink-action "deep" (path->string
                                  (build-path test-prefix "current-dir")))
          (remove-path-action (path->string
                               (build-path test-prefix "stamp.txt")))))
   #:prefix (path->string test-prefix))
  (check-true (file-exists? (build-path test-prefix "deep" "copied.txt")))
  (check-true (link-exists? (build-path test-prefix "current-dir")))
  (check-true (file-exists?
               (build-path test-prefix "current-dir" "copied.txt")))
  (check-false (file-exists? (build-path test-prefix "stamp.txt")))

  ;; Hostile paths never leave the prefix (kind 'config each).
  (define (config-kind thunk)
    (with-handlers ([exn:fail:pm? exn:fail:pm-kind])
      (thunk)
      #f))
  (define hostile-prefix (path->string test-prefix))
  (check-eq? (config-kind
              (lambda ()
                (local-perform!
                 (list->plan
                  (list (write-file-action
                         (path->string
                          (build-path test-prefix ".." "escape.txt"))
                         "x")))
                 #:prefix hostile-prefix)))
             'config)
  (check-eq? (config-kind
              (lambda ()
                (local-perform!
                 (list->plan
                  (list (symlink-action "/etc/hostname"
                                        (path->string
                                         (build-path test-prefix "bad")))))
                 #:prefix hostile-prefix)))
             'config)
  (check-eq? (config-kind
              (lambda ()
                (local-perform!
                 (list->plan
                  (list (remove-path-action hostile-prefix)))
                 #:prefix hostile-prefix)))
             'config)
  (check-eq? (config-kind
              (lambda ()
                (local-perform!
                 (list->plan
                  (list (write-file-action "/tmp/pm-nope.txt" "x"))))))
             'config)
  (check-eq? (config-kind
              (lambda ()
                (local-perform!
                 (list->plan
                  (list (extract-action "/v/m.git" "/tmp/staging"))))))
             'config)

  ;; Check without its executable refuses loudly (never silent).
  (define stub-error
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (local-perform!
       (list->plan
        (list (check-action '("bin/demo" "--version") "/pkg/1.0"))))
      'no-error))
  (check-pred config-error? stub-error)
  (check-regexp-match #rx"check executable not found"
                      (exn-message stub-error))

  ;; Run steps report E-8 fields on failure, pass quietly on success.
  (define sh-exe (path->string (find-executable-path "sh")))
  (local-perform!
   (list->plan
    (list (run-step-action "true-branch"
                           (list sh-exe "-c" "exit 0")
                           (path->string test-root)))))
  (define step-error
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (local-perform!
       (list->plan
        (list (run-step-action "boom"
                               (list sh-exe "-c" "exit 3")
                               (path->string test-root)))))
      'no-error))
  (check-pred build-error? step-error)
  (check-regexp-match #rx"exit-code: 3" (exn-message step-error))
  (check-regexp-match #rx"boom" (exn-message step-error))

  ;; Fetch plus extract against a file:// fixture mirror, end to end.
  (define (fixture-git-local dir . args)
    (define res
      (run-command (git-executable-path) args
                   #:cwd (path->string dir)
                   #:kind 'fetch #:operation "test-fixture"
                   #:env `(("GIT_AUTHOR_NAME" . "t")
                           ("GIT_AUTHOR_EMAIL" . "t@t")
                           ("GIT_COMMITTER_NAME" . "t")
                           ("GIT_COMMITTER_EMAIL" . "t@t")
                           ("HOME" . ,(path->string test-home))
                           ("GIT_CONFIG_NOSYSTEM" . "1"))))
    (unless (zero? (run-result-exit res))
      (error 'local-fixture "git failed: ~a" args))
    res)
  (define fixture-up (build-path test-root "upstream"))
  (make-directory fixture-up)
  (fixture-git-local fixture-up "init" "-b" "main" ".")
  (call-with-output-file (build-path fixture-up "f.txt")
    (lambda (port) (displayln "F" port)))
  (fixture-git-local fixture-up "add" "-A")
  (fixture-git-local fixture-up "commit" "-qm" "init")
  (define upstream-head
    (car (run-result-stdout-lines
          (fixture-git-local fixture-up "rev-parse" "HEAD"))))
  (define mirror-path (build-path test-vault "demo.git"))
  (define staging-path (build-path test-root "staging"))
  (parameterize ([current-allow-file-urls #t])
    (local-perform!
     (list->plan
      (list (fetch-action (string-append "file://" (path->string fixture-up))
                          upstream-head
                          (path->string mirror-path)))))
    (check-true (git-has-commit? mirror-path upstream-head))
    (local-perform!
     (list->plan
      (list (fetch-action (string-append "file://" (path->string fixture-up))
                          upstream-head
                          (path->string mirror-path)))))
    (local-perform!
     (list->plan
      (list (extract-action (path->string mirror-path)
                            (path->string staging-path))))
     #:commit upstream-head)
    (check-true (file-exists? (build-path staging-path "f.txt"))))

  ;; The E-11 actions: export, check, mark, clear, current. No stubs.
  (define e11-vault-git (build-path test-root "e11vault" "vault.git"))
  (make-directory* (build-path test-root "e11vault"))
  (define e11-stage (build-path test-root "e11stage"))
  (make-directory e11-stage)
  (define e11-pin
    (parameterize ([current-allow-file-urls #t])
      (vault-init e11-vault-git)
      (vault-add-result-pin
       (vault-add e11-vault-git "demo"
                  (string-append "file://" (path->string fixture-up))))))
  (parameterize ([current-allow-file-urls #t])
    (local-perform!
     (list->plan
      (list (export-action 'demo e11-pin (path->string e11-stage))))
     #:vault (path->string e11-vault-git))
    (check-true (file-exists? (build-path e11-stage "f.txt")))
    (check-false (directory-exists? (build-path e11-stage ".git"))))

  ;; Check runs exact argv in cwd: exit 0 passes, exit 3 is kind
  ;; 'build with the step name and exit code.
  (local-perform!
   (list->plan
    (list (check-action '("sh" "-c" "exit 0") (path->string test-prefix)))))
  (define check-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (local-perform!
       (list->plan
        (list (check-action '("sh" "-c" "exit 3")
                            (path->string test-prefix)))))
      'no-error))
  (check-pred build-error? check-err)
  (check-regexp-match #rx"exit-code: 3" (exn-message check-err))

  ;; Mark holds the marker and stays idempotent; clear removes it;
  ;; current flips atomically and re-flips to the second target.
  (define e11-ver (build-path test-root "ver"))
  (define e11-cur (build-path test-root "cur"))
  (define e11-ver2 (build-path test-root "ver2"))
  (make-directory e11-ver2)
  (local-perform!
   (list->plan (list (mark-incomplete-action (path->string e11-ver)))))
  (check-true (file-exists? (build-path e11-ver ".pm-incomplete")))
  (local-perform!
   (list->plan (list (mark-incomplete-action (path->string e11-ver)))))
  (local-perform!
   (list->plan
    (list (clear-incomplete-action (path->string e11-ver))
          (set-current-action (path->string e11-ver)
                              (path->string e11-cur)))))
  (check-false (file-exists? (build-path e11-ver ".pm-incomplete")))
  (check-equal? (path->string (resolve-path e11-cur))
                (path->string e11-ver))
  (local-perform!
   (list->plan
    (list (set-current-action (path->string e11-ver2)
                              (path->string e11-cur)))))
  (check-equal? (path->string (resolve-path e11-cur))
                (path->string e11-ver2))

  ;; Export without its vault refuses before touching anything.
  (define e11-nowhere (build-path test-root "e11nowhere"))
  (check-eq? (config-kind
              (lambda ()
                (local-perform!
                 (list->plan
                  (list (export-action 'demo e11-pin
                                       (path->string e11-nowhere)))))))
             'config)
  (check-false (directory-exists? e11-nowhere))

  (delete-directory/files test-root))

