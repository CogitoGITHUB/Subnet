#lang racket/base
;; build-lua.rkt -- manual E-12b driver: the first real build (Lua)
;; through apply. NOT in the gate: run by hand when the network and
;; the time allow. Reads docs/examples/lua.rktd, derives the real
;; plan (D-023 identity from the input hash), lowers it, drops ONLY
;; the fetch action (offline-safe: the vault already holds the pin;
;; fetch is proven over the network by hello-fetch and locally by
;; E-12; lowering also aims fetch and export at the same dir, a
;; Phase C item), and runs the rest through apply-plan over
;; local-perform! with the writer lock. Reports the build log tail,
;; the installed tree and bin/lua -v.

(require racket/cmdline
         racket/file
         racket/list
         "../core/errors.rkt"
         "../core/plan.rkt"
         "../core/scope.rkt"
         "../core/spec.rkt"
         "../core/spec-read.rkt"
         "../core/ui.rkt"
         "../core/version.rkt"
         "../backends/apply.rkt"
         "../backends/journal.rkt"
         "../backends/local.rkt"
         "../backends/run.rkt"
         "../backends/vault.rkt")

;; string any ... -> void, progress on stderr, stdout stays clean
(define (note fmt . args)
  (apply eprintf (string-append "[lua] " fmt "\n") args)
  (flush-output (current-error-port)))

;; fetch-progress -> void, one line per progress event
(define (report-progress p)
  (note "progress ~a ~a% ~a bytes"
        (fetch-progress-phase p)
        (fetch-progress-percent p)
        (fetch-progress-bytes p)))

;; path-string -> void, fresh work area or a like-new empty dir
(define (prepare-empty! dir what)
  (when (directory-exists? dir)
    (unless (null? (directory-list dir))
      (raise-pm-error 'config 'build-lua "work dir not empty"
                      #:fields `(("dir" . ,(path->string dir))
                                ("what" . ,what))
                      #:hint "pass --fresh to delete it first")))
  (make-directory* dir))

;; string -> void, the whole E-12b flow for one spec file
(define (run-build! spec-path fresh?)
  (define s (read-spec-file spec-path))
  (define name (symbol->string (spec-name s)))
  (define url (source-url (spec-source s)))
  (define pin (source-commit (spec-source s)))
  (define pp (derive-package-plan s '() '()))
  (define hash (package-plan-input-hash pp))
  (define ver (version->string (package-plan-version pp)))
  (define slot (symbol->string (package-plan-slot pp)))
  (define hash12 (substring hash 0 12))
  (define pin7 (substring pin 0 7))
  (define state (build-path (roots-data (scope-roots 'user)) "aiu-pm"))
  (define versioned (build-path state "store" (package-plan-store-dir pp)))
  (define current (build-path state "store" name slot "current"))
  (define cache (roots-cache (scope-roots 'user)))
  (define vault-git (build-path cache "aiu-pm" "vault.git"))
  (define work (build-path cache "aiu-pm" "build"
                           (string-append name "-" ver "-" pin7)))
  (define src (build-path work "src"))
  (define logf (build-path work "build.log"))
  (note "spec ~a name=~a version=~a pin=~a" spec-path name ver pin)
  (note "identity ~a hash12=~a" (package-plan-store-dir pp) hash12)
  (when fresh?
    (for ([d (in-list (list work versioned))])
      (when (directory-exists? d)
        (note "DELETE ~a (--fresh)" (path->string d))
        (delete-directory/files d))))
  ;; A clean versioned dir without its marker is already built.
  (when (and (directory-exists? versioned)
             (not (file-exists? (build-path versioned ".pm-incomplete"))))
    (note "already built ~a" (path->string versioned))
    (report! versioned current state name slot logf #t)
    (exit 0))
  (when (directory-exists? versioned)
    (raise-pm-error 'config 'build-lua "stale marked dir blocks the build"
                    #:fields `(("dir" . ,(path->string versioned)))
                    #:hint "pass --fresh to delete it first"))
  ;; Warm vault means no network: the pin is already there. Cold
  ;; means one real fetch, exactly like hello-fetch.
  (define warm?
    (and (directory-exists? vault-git)
         (with-handlers ([exn:fail? (lambda (e) #f)])
           (member name (vault-list vault-git)))))
  (if warm?
      (note "vault warm ~a, no fetch" (path->string vault-git))
      (let ([added (begin
                      (note "vault cold, fetching ~a" url)
                      (make-directory* (build-path cache "aiu-pm"))
                      (vault-init vault-git)
                      (vault-add vault-git name url #:pin pin
                                 #:on-progress report-progress
                                 #:fsck-allow '()))])
        (unless (and (string=? (vault-add-result-pin added) pin)
                     (eq? (vault-add-result-pin-source added) 'given))
          (raise-pm-error 'verify 'build-lua "vault pin is not the spec pin"
                           #:fields `(("spec" . ,pin))))))
  (prepare-empty! src "export")
  (define src-str (path->string src))
  (define ver-str (path->string versioned))
  (define actions
    (filter (lambda (a) (not (fetch-action? a)))
            (lower-package-plan pp url src-str ver-str
                                (path->string current))))
  (note "lowered ~a actions (fetch skipped, see header)" (length actions))
  (define (perform! a)
    (local-perform! (list->plan (list a))
                    #:prefix ver-str
                    #:commit pin
                    #:vault (path->string vault-git)))
  (call-with-output-file logf
    (lambda (log-out)
      (parameterize ([current-run-log-port log-out])
        (apply-plan (list->plan actions) hash perform!
                    #:state (path->string state)
                    #:package name
                    #:slot slot
                    #:writer (list "build-lua" "manual E-12b"))))
    #:exists 'truncate/replace)
  (note "apply ok")
  (report! versioned current state name slot logf #f))

;; path path path string string string path boolean -> void, the show
(define (report! versioned current state name slot logf already?)
  (when (and (not already?) (file-exists? logf))
    (define lines (file->lines logf))
    (define tail (drop lines (max 0 (- (length lines) 15))))
    (displayln "--- build log tail ---")
    (for ([line (in-list tail)])
      (displayln line)))
  (displayln "--- installed tree (ls -lR) ---")
  (define ls-res
    (run-command (find-executable-path "ls")
                 (list "-lR" (path->string versioned))
                 #:cwd (path->string state)
                 #:kind 'build #:operation "build-lua-ls"))
  (for ([line (in-list (run-result-stdout-lines ls-res))])
    (displayln line))
  (displayln "--- bin/lua -v ---")
  (define v-res
    (run-command (build-path versioned "bin" "lua") '("-v")
                 #:cwd (path->string versioned)
                 #:kind 'build #:operation "build-lua-verify"))
  (for ([line (in-list (append (run-result-stdout-lines v-res)
                               (run-result-stderr-lines v-res)))])
    (displayln line))
  (displayln "--- journal ---")
  (displayln (file->string (journal-file (path->string state) name slot)))
  (flush-output))

(module+ main
  (define fresh? #f)
  (define given
    (command-line
     #:program "build-lua"
     #:once-each
     [("--fresh") "delete the work and versioned dirs before building"
      (set! fresh? #t)]
     #:args (spec) spec))
  (exit
   (with-handlers
       ([exn:fail:pm?
         (lambda (e) (display-pm-error e) (pm-error-exit-code e))])
     (run-build! given fresh?)
     0)))
