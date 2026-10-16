#lang racket/base
;; install.rkt -- the install phase: place a built tree into PREFIX
;; (ENGINE.org backends/install.rkt, E-09).
;;
;; No fork of the placement logic: install-actions! refuses anything
;; that is not a placement action, then runs the list through
;; local-perform! from backends/local.rkt (D-025 keeps it the single
;; placement implementation). Fetch, run steps and the E-11 actions
;; therefore fail with kind 'config before anything runs: the install
;; phase can never fetch or build. PREFIX is explicit; no HOME, no
;; XDG, no environment reads anywhere in this module.

(require racket/contract/base
         "./local-perform.rkt"
         "../errors/error-type.rkt"
         "../spec/plan.rkt")

(provide
 (contract-out
  ;; (listof action) #:prefix -> void, install phase through local
  [install-actions! (-> (listof action?) #:prefix path-string? void?)]))

;; any -> boolean, the four placement actions local-perform! owns
(define (install-action? a)
  (or (install-file-action? a)
      (write-file-action? a)
      (symlink-action? a)
      (remove-path-action? a)))

;; (listof action) #:prefix -> void, non-install refuses first
(define (install-actions! actions #:prefix prefix)
  (for ([a (in-list actions)])
    (unless (install-action? a)
      (raise-pm-error 'config 'install-actions!
                      "not an install action"
                      #:fields `(("value" . ,(format "~s" a))))))
  (local-perform! (list->plan actions) #:prefix prefix #:commit #f))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/path
           "../errors/error-type.rkt"
           "../spec/plan.rkt")

  ;; All fixtures are synthetic (T-10) under one temp root: a fake
  ;; built tree plus a prefix. Nothing reads the real home or XDG.
  (define test-root (build-path (find-system-path 'temp-dir)
                                "pm-install-test"))
  (when (directory-exists? test-root)
    (delete-directory/files test-root))
  (define built (build-path test-root "built"))
  (define prefix-dir (build-path test-root "prefix"))
  (make-directory* (build-path built "bin"))
  (make-directory* (build-path built "lib"))
  (make-directory* prefix-dir)
  (call-with-output-file (build-path built "bin" "prog")
    (lambda (out) (display "prog-bytes" out)))
  (call-with-output-file (build-path built "lib" "libx.a")
    (lambda (out) (display "lib-bytes" out)))

  ;; install-file-action places bytes under PREFIX with its mode.
  (define prog-dst (build-path prefix-dir "bin" "prog"))
  (install-actions!
   (list (install-file-action (path->string (build-path built "bin" "prog"))
                              (path->string prog-dst)
                              #o755))
   #:prefix prefix-dir)
  (check-equal? (file->string prog-dst) "prog-bytes")
  (check-not-false (member 'execute
                           (file-or-directory-permissions prog-dst)))

  ;; write-file-action writes generated content under PREFIX.
  (install-actions!
   (list (write-file-action
          (path->string (build-path prefix-dir "share" "generated.txt"))
          "gen"))
   #:prefix prefix-dir)
  (check-equal? (file->string (build-path prefix-dir "share"
                                          "generated.txt"))
                "gen")

  ;; symlink-action links inside PREFIX; remove-path-action clears.
  (define stale (build-path prefix-dir "stale.txt"))
  (call-with-output-file stale (lambda (out) (display "stale" out)))
  (define link (build-path prefix-dir "link-to-prog"))
  (install-actions!
   (list (symlink-action (path->string prog-dst) (path->string link))
         (remove-path-action (path->string stale)))
   #:prefix prefix-dir)
  (check-true (link-exists? link))
  (check-equal? (path->string (resolve-path link))
                (path->string prog-dst))
  (check-false (file-exists? stale))

  ;; Remove is idempotent: a second pass is void, never an error.
  (check-not-exn
   (lambda ()
     (install-actions!
      (list (remove-path-action (path->string stale)))
      #:prefix prefix-dir)))

  ;; A dest escaping PREFIX refuses with kind 'config.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (install-actions!
                 (list (install-file-action
                        (path->string (build-path built "bin" "prog"))
                        (path->string (build-path prefix-dir ".."
                                                  "escape.txt"))
                        #o644))
                 #:prefix prefix-dir)
                'no-error))

  ;; An absolute path outside PREFIX refuses before anything writes.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (install-actions!
                 (list (write-file-action
                        "/definitely-outside-prefix-pm-test.txt" "x"))
                 #:prefix prefix-dir)
                'no-error))
  (check-false (file-exists? "/definitely-outside-prefix-pm-test.txt"))

  ;; Non-install actions refuse before anything runs: no fetch and
  ;; no run steps inside the install phase.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (install-actions!
                 (list (fetch-action "https://example.invalid/r.git"
                                     "abc123"
                                     "/tmp/pm-no-such-stage"))
                 #:prefix prefix-dir)
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (install-actions!
                 (list (run-step-action "make" '("make") "/tmp"))
                 #:prefix prefix-dir)
                'no-error))

  ;; Empty install is a no-op, not an error.
  (check-not-exn (lambda () (install-actions! '() #:prefix prefix-dir)))
  (delete-directory/files test-root))
