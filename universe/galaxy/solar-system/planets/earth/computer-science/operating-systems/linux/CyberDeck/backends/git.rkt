#lang racket/base
;; git.rkt -- git operations through run.rkt only. No git code in core/
;; beyond pure validation. Every command pins argv lists, explicit cwd,
;; timeouts, and the isolated config environment (item 7).

(require racket/contract/base
         racket/string
         racket/file
         "../core/errors.rkt"
         "../core/git-id.rkt"
         "../core/git-url.rkt"
         "run.rkt")

(provide
 (contract-out
  ;; -> path, missing git is kind 'config (F-2)
  [git-executable-path (-> path?)]
  ;; path-string string -> path, D-8 names, containment by construction
  [vault-mirror-dir (-> path-string? string? path?)]
  ;; string path -> void, init-bare + config + remote + fetch (D-011)
  [git-clone-mirror (->* (string? path-string?)
                         (#:timeout exact-positive-integer?)
                         void?)]
  ;; path -> void, fetch refspec, never --prune (D-011)
  [git-fetch-mirror (->* (path-string?)
                         (#:timeout exact-positive-integer?)
                         void?)]
  ;; path string -> boolean; #t iff the type is commit (exit table probed)
  [git-has-commit? (->* (path-string? string?)
                         (#:timeout exact-positive-integer?)
                         boolean?)]
;; path string -> void, idempotent pin ref; missing means kind 'verify
  [git-pin-commit (->* (path-string? string?)
                         (#:timeout exact-positive-integer?)
                         void?)]))

;; ---------------------------------------------------------------------------
;; Locating git and the vault

;; -> path, missing git is kind 'config (F-2: fail clearly if missing)
(define (git-executable-path)
  (or (find-executable-path "git")
      (raise-pm-error 'config 'git-executable-path "git executable not found"
                      #:hint "install git so the package manager can fetch")))

;; path-string string -> path
;; Validated D-8 package names cannot hold '/' or '..', so containment in
;; the vault root holds by construction (F-7).
(define (vault-mirror-dir vault-root name)
  (unless (regexp-match? #rx"^[a-z0-9][a-z0-9-]*$" name)
    (raise-pm-error 'spec 'vault-mirror-dir "invalid package name for vault"
                    #:fields `(("name" . ,name))))
  (build-path vault-root (string-append name ".git")))

;; -> path, the pm-owned optional global config (item 7)
(define (git-global-config-path)
  (build-path (find-system-path 'home-dir) ".config" "cyberdeck" "gitconfig"))

;; -> (listof (cons string string)), isolated non-interactive env (item 7, 3)
(define (git-env)
  `(("GIT_CONFIG_NOSYSTEM" . "1")
    ("GIT_CONFIG_GLOBAL" . ,(path->string (git-global-config-path)))
    ("GIT_TERMINAL_PROMPT" . "0")))

;; ---------------------------------------------------------------------------
;; Running git with uniform failure handling

;; string run-result -> run-result, dubious ownership means kind 'config (15)
(define (check-dubious op res)
  (define lines
    (append (run-result-stdout-lines res) (run-result-stderr-lines res)))
  (when (and (not (zero? (run-result-exit res)))
             (ormap (lambda (l) (regexp-match? #rx"dubious ownership" l))
                    lines))
    (raise-pm-error 'config op "git reports unsafe repository ownership"
                    #:fields `(("detail" . ,(string-join lines "\n")))
                    #:hint "inspect the mirror directory ownership"))
  res)

;; Note on `--` separators: intentionally absent. Every URL, commit id,
;; and name reaching argv is strictly validated first (check-git-url with
;; the scheme allowlist, git-id? hex-only, D-8 package names), so no
;; argument can start with `-` or contain whitespace. Several git verbs
;; do not accept `--` in these positions, so blanket separators would
;; break commands for zero gain. Say the word and it gets re-tested.

;; path symbol path-string (listof string) -> run-result
(define (git-run git op dir argv #:kind kind #:timeout timeout
                 #:operation operation)
  (define res
    (run-command git argv
                 #:cwd dir
                 #:kind kind
                 #:timeout timeout
                 #:operation operation
                 #:env (git-env)))
  (check-dubious op res)
  res)

;; symbol path string run-result pm-kind -> never returns (E-8 fields)
(define (raise-git-failure op dir command res kind)
  (raise-pm-error kind op "git command failed"
                  #:fields `(("mirror" . ,(path->string dir))
                             ("command" . ,command)
                             ("exit-code"
                              . ,(number->string (run-result-exit res)))
                             ("stderr" . ,(string-join
                                           (run-result-stderr-lines res)
                                           "\n")))))

;; path symbol path-string (listof string) -> void, nonzero raises kind (E-8)
(define (git-run! git op dir argv #:kind kind #:timeout timeout
                  #:operation operation)
  (define res (git-run git op dir argv #:kind kind #:timeout timeout
                       #:operation operation))
  (unless (zero? (run-result-exit res))
    (raise-pm-error kind op "git command failed"
                    #:fields `(("command" . ,(string-join
                                               (cons (path->string git) argv)
                                               " "))
                               ("exit-code"
                                . ,(number->string (run-result-exit res)))
                               ("stderr" . ,(string-join
                                             (run-result-stderr-lines res)
                                             "\n"))))))

;; string -> boolean, ssh:// or scp-like user@host:path
(define (ssh-like-url? url)
  (or (string-prefix? url "ssh://")
      (regexp-match? #rx"^[^/:@]+@[^/:@]+:" url)))

;; exn -> boolean, our own timeout shape from run.rkt
(define (timeout-exn? e)
  (and (exn:fail:pm? e)
       (regexp-match? #rx"timed out" (exn-message e))))

;; string pm-kind symbol exn:fail:pm -> never returns, ssh hint on ssh (14)
(define (raise-ssh-timeout url kind op e)
  (if (and url (ssh-like-url? url))
      (raise-pm-error kind op "command timed out"
                      #:fields (exn:fail:pm-fields e)
                      #:hint (string-append
                              "ssh may be waiting at a prompt; connect once "
                              "manually to accept the host key.")
                      #:cause e)
      (raise e)))

;; string pm-kind symbol (-> any) -> any, ssh hint on ssh timeouts (14)
(define (with-ssh-timeout-hint url kind op thunk)
  (with-handlers ([timeout-exn? (lambda (e) (raise-ssh-timeout url kind op e))])
    (thunk)))

;; ---------------------------------------------------------------------------
;; Per-mirror locking (item 12): fcntl via racket/file, released on death.

;; path -> path
(define (mirror-lock-path mirror-dir)
  (define-values (base name _dir?)
    (split-path mirror-dir))
  (build-path base (string-append (path->string name) ".lock")))

;; path pm-kind symbol exact-int (-> any) -> any
(define (with-mirror-lock mirror-dir kind op timeout thunk)
  (call-with-file-lock/timeout
   mirror-dir 'exclusive thunk
   (lambda ()
     (raise-pm-error kind op "could not acquire mirror lock"
                     #:fields `(("mirror" . ,(path->string mirror-dir))
                                ("timeout-seconds" . ,(number->string timeout)))))
   #:lock-file (mirror-lock-path mirror-dir)
   #:max-delay timeout))

;; ---------------------------------------------------------------------------
;; Commit validation and lookup

;; symbol string -> void, every commit checked before argv (item 3)
(define (check-commit op commit)
  (unless (git-id? commit)
    (raise-pm-error 'spec op "not a commit id"
                    #:fields `(("value" . ,commit)))))

;; path -> (or/c string? #f), remote URL for messages, #f when unreadable
(define (mirror-origin-url dir)
  (define git (git-executable-path))
  (define res
    (git-run git 'mirror-origin-url dir '("config" "--get" "remote.origin.url")
             #:kind 'fetch #:timeout 30 #:operation "read remote url"))
  (and (zero? (run-result-exit res))
       (pair? (run-result-stdout-lines res))
       (car (run-result-stdout-lines res))))

;; ---------------------------------------------------------------------------
;; Operations

;; string path -> void, fresh bare mirror with pinned config (D-011, 4, 6)
(define (git-clone-mirror url dir #:timeout [timeout 600])
  (check-git-url url)
  (define git (git-executable-path))
  (define-values (parent _name _dir?) (split-path dir))
  (unless (directory-exists? parent)
    (raise-pm-error 'config 'git-clone-mirror "vault root missing"
                    #:fields `(("parent" . ,(path->string parent)))
                    #:hint "create the vault root first"))
  (when (or (file-exists? dir) (directory-exists? dir) (link-exists? dir))
    (raise-pm-error 'config 'git-clone-mirror "mirror already exists"
                    #:fields `(("mirror" . ,(path->string dir)))
                    #:hint "fetch into it instead"))
  (with-mirror-lock dir 'fetch 'git-clone-mirror timeout
    (lambda ()
      (define tmp
        (build-path parent (format ".tmp-clone-~a-~a"
                                   (current-milliseconds) (gensym))))
      (dynamic-wind
        void
        (lambda ()
          (with-ssh-timeout-hint url 'fetch 'git-clone-mirror
            (lambda ()
              ;; Bare repo with an empty template: no hooks installed (7).
              (git-run! git 'git-clone-mirror parent
                        `("init" "--bare" "--template=" "--"
                          ,(path->string tmp))
                        #:kind 'fetch #:timeout timeout
                        #:operation "git init mirror")
              ;; Keep everything so original code is never lost (item 8).
              (for ([kv (in-list '(("core.logAllRefUpdates" . "always")
                                    ("transfer.fsckObjects" . "true")
                                    ("gc.pruneExpire" . "never")
                                    ("gc.reflogExpire" . "never")
                                    ("gc.reflogExpireUnreachable" . "never")))])
                (git-run! git 'git-clone-mirror tmp
                          `("config" ,(car kv) ,(cdr kv))
                          #:kind 'fetch #:timeout timeout
                          #:operation "git config mirror"))
              (git-run! git 'git-clone-mirror tmp
                        `("remote" "add" "origin" "--" ,url)
                        #:kind 'fetch #:timeout timeout
                        #:operation "git remote add")
              ;; Upstream refs land under refs/upstream/*; never --prune (4).
              (git-run! git 'git-clone-mirror tmp
                        `("fetch" "origin" "--" "+refs/*:refs/upstream/*")
                        #:kind 'fetch #:timeout timeout
                        #:operation "git fetch mirror")))
          (rename-file-or-directory tmp dir))
        (lambda ()
          (when (directory-exists? tmp)
            (delete-directory/files tmp)))))))

;; path -> void, fetch refspec, never --prune (D-011)
(define (git-fetch-mirror dir #:timeout [timeout 300])
  (define git (git-executable-path))
  (with-mirror-lock dir 'fetch 'git-fetch-mirror timeout
    (lambda ()
      (define url (mirror-origin-url dir))
      (with-ssh-timeout-hint url 'fetch 'git-fetch-mirror
        (lambda ()
          (git-run! git 'git-fetch-mirror dir
                    '("fetch" "origin" "--" "+refs/*:refs/upstream/*")
                    #:kind 'fetch #:timeout timeout
                    #:operation "git fetch mirror"))))))

;; path string -> boolean; #t iff the type is commit (exit table probed)
(define (git-has-commit? dir commit #:timeout [timeout 30])
  (check-commit 'git-has-commit? commit)
  (define git (git-executable-path))
  ;; Existence first (-e: absent means 1), then the type (-t: a missing
  ;; object there means 128, so -t alone cannot tell absent from broken).
  (define exists
    (git-run git 'git-has-commit? dir `("cat-file" "-e" "--" ,commit)
             #:kind 'fetch #:timeout timeout #:operation "git cat-file"))
  (cond [(not (zero? (run-result-exit exists)))
         (if (= 1 (run-result-exit exists))
             #f
             (raise-git-failure 'git-has-commit? dir
                                (string-append "cat-file -e " commit)
                                exists 'fetch))]
        [else
         (let ([typed
                (git-run git 'git-has-commit? dir `("cat-file" "-t" "--" ,commit)
                         #:kind 'fetch #:timeout timeout
                         #:operation "git cat-file")])
           (cond [(and (zero? (run-result-exit typed))
                       (equal? (run-result-stdout-lines typed) '("commit")))
                  #t]
                 [(zero? (run-result-exit typed)) #f]
                 [else
                  (raise-git-failure 'git-has-commit? dir
                                     (string-append "cat-file -t " commit)
                                     typed 'fetch)]))]))

;; path string -> void, idempotent pin ref; missing means kind 'verify (13)
(define (git-pin-commit dir commit #:timeout [timeout 30])
  (check-commit 'git-pin-commit commit)
  (define git (git-executable-path))
  (with-mirror-lock dir 'verify 'git-pin-commit timeout
    (lambda ()
      (unless (git-has-commit? dir commit #:timeout timeout)
        (raise-pm-error 'verify 'git-pin-commit "commit missing from mirror"
                        #:fields `(("commit" . ,commit)
                                   ("url" . ,(or (mirror-origin-url dir) "?"))
                                   ("mirror" . ,(path->string dir)))
                        #:hint "upstream may have rewritten history"))
      (git-run! git 'git-pin-commit dir
                `("update-ref" "--"
                  ,(string-append "refs/cyberdeck/pinned/" commit)
                  ,commit)
                #:kind 'verify #:timeout timeout
                #:operation "git update-ref pin"))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/string
           racket/system
           "../core/errors.rkt")

  (define git-exe (git-executable-path))
  (check-pred path-string? git-exe)
  (check-true (file-exists? git-exe))

  (define fixture-root (make-temporary-directory "pm-git~a"))
  (define fixture-home (build-path fixture-root "home"))
  (make-directory fixture-home)

  ;; Extra env for fixture git commands: identity, isolated HOME,
  ;; no system config (item 8).
  (define (fixture-env)
    `(("GIT_AUTHOR_NAME" . "t")
      ("GIT_AUTHOR_EMAIL" . "t@t")
      ("GIT_COMMITTER_NAME" . "t")
      ("GIT_COMMITTER_EMAIL" . "t@t")
      ("HOME" . ,(path->string fixture-home))
      ("GIT_CONFIG_NOSYSTEM" . "1")))

  ;; Run git for fixtures; nonzero raises.
  (define (fixture-git dir . args)
    (define res
      (run-command git-exe args
                   #:cwd (path->string dir)
                   #:kind 'fetch #:timeout 60 #:operation "test-fixture"
                   #:env (fixture-env)))
    (unless (zero? (run-result-exit res))
      (error 'fixture "git failed: ~a" args))
    res)

  ;; string (listof (cons string string)) -> path-string commit id
  (define (make-upstream name files)
    (define dir (build-path fixture-root name))
    (make-directory dir)
    (fixture-git dir "init" "-b" "main" ".")
    (for ([f (in-list files)])
      (call-with-output-file (build-path dir (car f))
        (lambda (port) (displayln (cdr f) port))))
    (fixture-git dir "add" "-A")
    (fixture-git dir "commit" "-qm" "init")
    (values dir
            (car (run-result-stdout-lines
                  (fixture-git dir "rev-parse" "HEAD")))))

  (define file-url
    (string-append "file://" (path->string fixture-root) "/upstream"))

  ;; vault-mirror-dir builds and rejects.
  (check-equal? (vault-mirror-dir "/v/root" "racket-mode")
                (build-path "/v/root" "racket-mode.git"))
  (for ([bad (in-list '("Bad!" "../escape" "" "a/b"))])
    (check-exn exn:fail:pm?
               (lambda () (vault-mirror-dir "/v/root" bad))))

  ;; Hostile argv never reaches git: validation rejects before any spawn.
  (for ([hostile (in-list '("--upload-pack=evil"
                             "$(touch /tmp/pm-pwned)"
                             "a;b"
                             "https://example.org/x.git\nMALICIOUS"))])
    (check-pred spec-error?
                (with-handlers ([exn:fail:pm? (lambda (e) e)])
                  (git-clone-mirror hostile
                                    (build-path fixture-root "hostile.git")))))
  (check-pred spec-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (git-has-commit? (build-path fixture-root "hostile.git")
                                 "--not-a-commit")))
  (check-false (file-exists? "/tmp/pm-pwned"))

  (parameterize ([current-allow-file-urls #t])
    ;; Clone, fetch, and the four commit-probe cases (item 5).
    (define-values (upstream head-commit)
      (make-upstream "upstream" '(("a.txt" . "A"))))
    (define mirror (vault-mirror-dir fixture-root "demo"))
    (git-clone-mirror (string-append "file://" (path->string upstream))
                      mirror)
    (check-true (git-has-commit? mirror head-commit))
    ;; Well-formed but absent id, and tree id: both #f.
    (check-false (git-has-commit? mirror (make-string 40 #\a)))
    (define tree-id
      (car (run-result-stdout-lines
            (fixture-git upstream "rev-parse" (string-append head-commit
                                                             "^{tree}")))))
    (check-false (git-has-commit? mirror tree-id))
    ;; Not a repo raises kind 'fetch.
    (define empty-dir (build-path fixture-root "empty"))
    (make-directory empty-dir)
    (check-pred fetch-error?
                (with-handlers ([exn:fail:pm? (lambda (e) e)])
                  (git-has-commit? empty-dir head-commit)))

    ;; Pin is idempotent; missing commits raise kind 'verify (item 13).
    (git-pin-commit mirror head-commit)
    (git-pin-commit mirror head-commit)
    (define pin-ref (string-append "refs/cyberdeck/pinned/" head-commit))
    (check-equal?
     (run-result-exit
      (fixture-git mirror "rev-parse" "--verify" "--quiet" pin-ref))
     0)
    (define missing-exn
      (with-handlers ([exn:fail:pm? (lambda (e) e)])
        (git-pin-commit mirror (make-string 40 #\b))))
    (check-pred verify-error? missing-exn)
    (check-equal? (cdr (assoc "commit" (exn:fail:pm-fields missing-exn)))
                  (make-string 40 #\b))
    (check-true
     (regexp-match? #rx"rewritten"
                    (or (exn:fail:pm-hint missing-exn) "")))

    ;; Pin survival: unreachable upstream + gc + prune config (item 4).
    (fixture-git upstream "checkout" "-qb" "doomed")
    (call-with-output-file (build-path upstream "gone.txt")
      (lambda (port) (displayln "gone" port)))
    (fixture-git upstream "add" "-A")
    (fixture-git upstream "commit" "-qm" "doomed")
    (define doomed
      (car (run-result-stdout-lines
            (fixture-git upstream "rev-parse" "HEAD"))))
    (fixture-git upstream "checkout" "-q" "main")
    (git-fetch-mirror mirror)
    (git-pin-commit mirror doomed)
    (fixture-git upstream "branch" "-D" "doomed")
    (git-fetch-mirror mirror)
    (check-true (git-has-commit? mirror doomed))
    (fixture-git mirror "gc" "--prune=now")
    (check-true (git-has-commit? mirror doomed))
    (fixture-git mirror "config" "fetch.prune" "true")
    (fixture-git upstream "branch" "junk" "main")
    (fixture-git upstream "branch" "-D" "junk")
    (git-fetch-mirror mirror)
    (check-true (git-has-commit? mirror doomed))

    ;; Hostile global config is ignored (item 7).
    (define hostile-home (build-path fixture-root "hostile-home"))
    (make-directory hostile-home)
    (call-with-output-file (build-path hostile-home ".gitconfig")
      (lambda (port)
        (displayln "[url \"file:///hijack/\"]" port)
        (displayln "\tinsteadOf = file://" port)
        (displayln "[core]" port)
        (displayln "\thooksPath = /tmp/pm-no-such-hooks" port)))
    (define hostile-env
      `(("GIT_AUTHOR_NAME" . "t")
        ("GIT_AUTHOR_EMAIL" . "t@t")
        ("GIT_COMMITTER_NAME" . "t")
        ("GIT_COMMITTER_EMAIL" . "t@t")
        ("HOME" . ,(path->string hostile-home))
        ("GIT_CONFIG_NOSYSTEM" . "1")))
    (define hostile-mirror (vault-mirror-dir fixture-root "hostile"))
    (parameterize ([current-environment-variables
                    (let ([e (make-environment-variables #"PATH" #"HOME")])
                      (environment-variables-set!
                       e #"PATH" (string->bytes/utf-8 (getenv "PATH")))
                      (for ([p (in-list hostile-env)])
                        (environment-variables-set!
                         e
                         (string->bytes/utf-8 (car p))
                         (string->bytes/utf-8 (cdr p))))
                      e)])
      (git-clone-mirror (string-append "file://" (path->string upstream))
                        hostile-mirror)
      (check-true (git-has-commit? hostile-mirror head-commit))))

  ;; GIT_CONFIG_GLOBAL is honored (item 7): a controlled global file
  ;; supplies a value nothing else could provide.
  (define global-probe (make-temporary-file "pm-global~a"))
  (call-with-output-file global-probe
    (lambda (port)
      (displayln "[user]" port)
      (displayln "\tname = pm-probe-value" port))
    #:exists 'truncate/replace)
  (define probe-res
    (run-command git-exe '("config" "user.name")
                 #:cwd (path->string fixture-root)
                 #:kind 'fetch #:timeout 30 #:operation "test-global"
                 #:env `(("GIT_CONFIG_NOSYSTEM" . "1")
                         ("GIT_CONFIG_GLOBAL" . ,(path->string global-probe))
                         ("HOME" . ,(path->string fixture-home)))))
  (check-equal? (run-result-stdout-lines probe-res) '("pm-probe-value"))
  (delete-file global-probe)

  ;; Dubious ownership maps to kind 'config; clean failures pass through.
  (define dubious
    (run-result 128 '() '("fatal: detected dubious ownership in repository")))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (check-dubious 'git-fetch dubious)))
  (define clean-res (run-result 1 '("x") '()))
  (check-eq? (check-dubious 'git-fetch clean-res) clean-res)

  ;; SSH timeouts gain the host-key hint; others re-raise unchanged (14).
  (define timeout-exn
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (raise-pm-error 'fetch 'git-fetch-mirror "command timed out"
                      #:fields '(("operation" . "git fetch")))))
  (define ssh-hinted
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (raise-ssh-timeout "ssh://git@example.org/x.git" 'fetch
                         'git-fetch-mirror timeout-exn)))
  (check-pred fetch-error? ssh-hinted)
  (check-true
   (regexp-match? #rx"host key" (or (exn:fail:pm-hint ssh-hinted) "")))
  (check-eq? (exn:fail:pm-cause ssh-hinted) timeout-exn)
  (check-eq? (with-handlers ([exn:fail:pm? (lambda (e) e)])
               (raise-ssh-timeout "https://example.org/x.git" 'fetch
                                  'git-fetch-mirror timeout-exn))
             timeout-exn)

  ;; Locking across processes with kill -9 release (item 12).
  ;; If fcntl locks misbehave under proot this fails: STOP and ask.
  (define lock-file (build-path fixture-root "test.lock"))
  (define holder-path (build-path fixture-root "holder.rkt"))
  (define ready-path (build-path fixture-root "holder-ready"))
  (call-with-output-file holder-path
    (lambda (port)
      (displayln "#lang racket/base" port)
      (displayln "(require racket/file)" port)
      (displayln "(call-with-file-lock/timeout" port)
      (displayln (format "  ~s 'exclusive" (path->string lock-file)) port)
      (displayln "  (lambda ()" port)
      (displayln (format "    (call-with-output-file ~s" (path->string ready-path)) port)
      (displayln "      (lambda (p) (displayln \"ready\" p)))" port)
      (displayln "    (sleep 120))" port)
      (displayln "  (lambda () (displayln \"holder failed\") (exit 1))" port)
      (displayln (format "  #:lock-file ~s)" (path->string lock-file)) port)))
  (define holder
    (process* (find-system-path 'exec-file) (path->string holder-path)))
  (define holder-pid (list-ref holder 2))
  (define holder-ctl (list-ref holder 4))
  ;; Wait for the holder to actually hold the lock (bounded).
  (let wait-loop ([n 0])
    (unless (file-exists? ready-path)
      (when (> n 60)
        (error 'lock-test "holder never became ready"))
      (sleep 1)
      (wait-loop (+ n 1))))
  ;; Contender loses while the holder lives.
  (check-equal?
   (call-with-file-lock/timeout (path->string lock-file) 'exclusive
                                (lambda () 'contender-won)
                                (lambda () 'contender-failed)
                                #:lock-file (path->string lock-file)
                                #:max-delay 1)
   'contender-failed)
  ;; kill -9 the holder; fcntl releases the lock.
  (define killer
    (process* (find-executable-path "sh") "-c"
              (format "kill -9 ~a" holder-pid)))
  ((list-ref killer 4) 'wait)
  (sleep 1)
  (check-equal?
   (call-with-file-lock/timeout (path->string lock-file) 'exclusive
                                (lambda () 'contender-won)
                                (lambda () 'contender-failed)
                                #:lock-file (path->string lock-file)
                                #:max-delay 5)
   'contender-won)
  (holder-ctl 'wait)

  (delete-directory/files fixture-root))
