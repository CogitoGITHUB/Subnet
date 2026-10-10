#lang racket/base
;; scripts/probe-blob.rkt -- print exactly what vault-large-blobs reads.
;;
;; backends/vault.rkt:1611 expects vault-backup-push to refuse a namespace
;; holding a blob over 100000000 bytes, and it does not. That check reads
;; two things (vault.rkt:852-876): the `cat-file --batch-check
;; --batch-all-objects` line for the blob, and whether the blob's sha is in
;; the `reachable` set built from `rev-list --objects`. This script builds
;; a SMALL repo, adds it to a vault through the project's own vault-add,
;; and prints both strings verbatim, so the two regexes at vault.rkt:870
;; and :902 can be compared against real output instead of assumed.
;;
;; It takes an optional byte count, so the same probe can be run small
;; (fast) and large (the real threshold). Synthetic data only (T-10).

(require racket/file
         racket/port
         racket/string
         racket/system
         "../backends/vault.rkt"
         "../core/errors.rkt"
         "../core/git-url.rkt")

(define bytes (if (> (vector-length (current-command-line-arguments)) 0)
                  (string->number
                   (vector-ref (current-command-line-arguments) 0))
                  4096))

(define root (build-path (or (getenv "XDG_CACHE_HOME")
                            (build-path (getenv "HOME") ".cache"))
                         "cyberdeck"
                         "probe-blob"))
(when (directory-exists? root) (delete-directory/files root))
(make-directory* (build-path root "up"))

;; the fixture, exactly as vault.rkt:1591-1600 builds it
(define big-dir (build-path root "up"))
(define out (open-output-file (build-path big-dir "big") #:exists 'truncate))
(define filler
  (parameterize ([current-directory big-dir])
    (process* "/usr/bin/head" "-c" (number->string bytes) "/dev/urandom")))
(copy-port (list-ref filler 0) out)
(close-output-port out)
((list-ref filler 4) 'wait)

;; system* WAITS and returns the exit code. process* does not block, and an
;; unwaited commit races the fetch that follows it (measured: "empty remote
;; or unresolvable HEAD"). `git -C` is used instead of the cwd parameter so
;; the directory is explicit rather than inherited.
(define (git! . args)
  ;; This build's system* does not report an exit code the way process*
  ;; does, so nothing is asserted here: what this probe prints IS the
  ;; evidence, and an empty section is itself the finding.
  (apply system* "/usr/bin/git" "-C" (path->string big-dir) args)
  (void))

(git! "init" "-q" "-b" "main" ".")
(git! "add" "--" "big")
(git! "-c" "user.email=p@example.org" "-c" "user.name=probe"
      "commit" "-qm" "big")

(define on-disk (file-size (build-path big-dir "big")))
(printf "fixture bytes on disk: ~a\n" on-disk)

(define vault (build-path root "vault.git"))
(make-directory* vault)
(vault-init vault)
;; file:// is test-only in production, which is the same allowance the
;; vault's own fixtures use. Synthetic local data, no network.
(parameterize ([current-allow-file-urls #t])
  (vault-add vault "demo" (format "file://~a" (path->string big-dir))))

;; the three reads vault-large-blobs makes, printed verbatim
;; The point of this probe is to SHOW git's exact output lines, so git
;; writes straight to the screen: no capture, no ports, no path slots. This
;; build's process* demands a real path in all three slots and its return
;; value is not an exit code, so capturing through it was three wrong turns
;; before the simple thing was tried.
(define (show label git-args)
  (printf "\n=== ~a\n=== git ~a\n" label (string-join git-args " "))
  (flush-output)
  (apply system* "/usr/bin/git"
         (append (list "--git-dir" (path->string vault)) git-args))
  (void))

(show "tips (for-each-ref under the namespace)"
      (list "for-each-ref" "--format=%(objectname)" "--" "refs/vault/demo"))
(show "reachable (rev-list --objects)"
      (list "rev-list" "--objects" "refs/vault/demo/heads/main"))
(show "batch (cat-file --batch-check --batch-all-objects)"
      (list "cat-file" "--batch-check" "--batch-all-objects"))

(printf "\nthreshold in vault-big-line? is >100000000; this fixture is ~a bytes\n"
        on-disk)
(printf "PASSES-ONLY-IF-ABOVE-THRESHOLD: ~a\n" (> on-disk 100000000))
