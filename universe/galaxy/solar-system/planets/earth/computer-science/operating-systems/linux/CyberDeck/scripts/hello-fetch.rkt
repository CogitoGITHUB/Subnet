#lang racket/base
;; scripts/hello-fetch.rkt -- fetch and export a package using pm's OWN vault
;; code (P-01). There is no direct git call in this file: vault-init,
;; vault-add and vault-export-commit do every git operation and emit the pm
;; IN/OUT records themselves.
;;
;; Two modes:
;;   --discover URL NAME   add+fetch through the vault, print ONLY the pinned
;;                         commit id on stdout (records go to stderr)
;;   SPEC [--vault D] [--out D] [--fresh]
;;                         add+fetch the spec's EXACT commit, export it, and
;;                         verify the pin the vault reports is that commit
;;
;; racket/cmdline stops parsing flags at the first bare word, so NAME and SPEC
;; come LAST on the command line:
;;   racket scripts/hello-fetch.rkt --discover URL --fresh hello
;;   racket scripts/hello-fetch.rkt --vault D --out D --fresh SPEC
;;
;; Deletes nothing outside the cache, and only with --fresh. No timers, no
;; sleeps, no find (D-015).

(require racket/cmdline
         racket/file
         "../backends/vault.rkt"
         "../core/errors.rkt"
         "../core/spec.rkt"
         "../core/spec-read.rkt"
         "../core/ui.rkt")

;; The one and only place the environment is read.
(define (cache-dir)
  (define xdg (getenv "XDG_CACHE_HOME"))
  (if (and xdg (not (string=? xdg "")))
      xdg
      (build-path (getenv "HOME") ".cache")))

(define (default-vault) (build-path (cache-dir) "cyberdeck" "hello-vault"))
(define (default-out) (build-path (cache-dir) "cyberdeck" "hello-build"))

;; Progress and narration go to stderr so --discover can keep stdout pure.
(define (note fmt . args)
  (apply eprintf (string-append "[hello] " fmt "\n") args)
  (flush-output (current-error-port)))

(define (report-progress p)
  (note "progress ~a ~a% ~a bytes"
        (fetch-progress-phase p)
        (fetch-progress-percent p)
        (fetch-progress-bytes p)))

;; vault-add fetches as part of adding (vault-fetch-with-retry), so there is
;; no second call to make: vault-fetch-namespace is for REFETCHING a
;; namespace that is already there.
;;
;; #:fsck-allow is a list of git fsck message ids to DOWNGRADE to warnings
;; for this fetch (it becomes `-c fsck.<id>=ignore`). '() ignores nothing,
;; which is the honest default for a first fetch.

;; path-string boolean? -> void, fresh vault when asked or when missing
(define (prepare-vault! vault fresh?)
  (when (and fresh? (directory-exists? vault))
    (note "DELETE ~a (--fresh)" vault)
    (delete-directory/files vault))
  (when (or fresh? (not (directory-exists? vault)))
    (make-directory* vault)
    (note "vault-init ~a" vault)
    (vault-init vault #:on-progress report-progress)
    (note "vault-init done")))

;; path-string boolean? -> void, export only ever writes into an EMPTY dir
(define (prepare-out! out fresh?)
  (when (directory-exists? out)
    (unless (null? (directory-list out))
      (unless fresh?
        (raise-pm-error 'config 'hello-fetch "export dir not empty"
                        #:fields `(("dir" . ,(path->string out)))
                        #:hint "pass --fresh to delete it first"))
      (note "DELETE ~a (--fresh)" out)
      (delete-directory/files out)))
  (make-directory* out))

;; string string path-string boolean? -> void, stdout gets the commit id only
(define (discover! url name vault fresh?)
  (prepare-vault! vault fresh?)
  (note "vault-add ~a ~a" name url)
  (define r (vault-add vault name url
                       #:on-progress report-progress
                       #:fsck-allow '()))
  (printf "~a\n" (vault-add-result-pin r))
  (flush-output))

;; path-string path-string path-string boolean? -> void
(define (run-spec! spec-path vault out fresh?)
  (define s (read-spec-file spec-path))
  (define name (symbol->string (spec-name s)))
  (define url (source-url (spec-source s)))
  (define pin (source-commit (spec-source s)))
  (note "spec ~a name=~a pin=~a" spec-path name pin)
  (prepare-vault! vault fresh?)
  ;; #:pin makes the vault resolve and assert THIS commit; it raises rather
  ;; than silently moving on if the commit is unreachable.
  (define added (vault-add vault name url #:pin pin
                           #:on-progress report-progress
                           #:fsck-allow '()))
  ;; The vault's own verification: it reports the pin it used and where that
  ;; pin came from. 'given means the spec's commit, not a remote head.
  ;; vault-export-commit below re-checks the same commit with `cat-file -e`
  ;; and raises kind 'verify "commit missing from vault" if it is absent.
  (define got (vault-add-result-pin added))
  (define from (vault-add-result-pin-source added))
  (unless (and (string=? got pin) (eq? from 'given))
    (raise-pm-error 'verify 'hello-fetch "vault pin is not the spec commit"
                    #:fields `(("spec" . ,pin) ("vault" . ,got)
                               ("pin-source" . ,(format "~a" from)))))
  (note "verified pin ~a pin-source=~a" got from)
  (prepare-out! out fresh?)
  (note "vault-export-commit ~a -> ~a" pin out)
  (vault-export-commit vault name pin out #:on-progress report-progress)
  (note "export ok"))

(module+ main
  (define vault #f)
  (define out #f)
  (define fresh? #f)
  (define discover-url #f)
  (define given
    (command-line
     #:program "hello-fetch"
     #:once-each
     [("--vault") dir "vault directory (default: <cache>/cyberdeck/hello-vault)"
      (set! vault dir)]
     [("--out") dir "export directory (default: <cache>/cyberdeck/hello-build)"
      (set! out dir)]
     [("--fresh") "delete the vault and export dirs before running"
      (set! fresh? #t)]
     [("--discover") url "URL: fetch NAME, then print the pinned commit"
      (set! discover-url url)]
     ;; racket/cmdline's #:args is fixed arity, so the ONE positional is
     ;; NAME in --discover mode and the SPEC path in normal mode.
     #:args (given) given))
  (exit
   (with-handlers
       ([exn:fail:pm?
         (lambda (e) (display-pm-error e) (pm-error-exit-code e))]
        [exn:fail?
         (lambda (e) (display-internal-error e) 70)])
     (cond
       [discover-url
        (discover! discover-url given (or vault (default-vault)) fresh?)
        0]
       [else
        (run-spec! given (or vault (default-vault))
                   (or out (default-out)) fresh?)
        0]))))
