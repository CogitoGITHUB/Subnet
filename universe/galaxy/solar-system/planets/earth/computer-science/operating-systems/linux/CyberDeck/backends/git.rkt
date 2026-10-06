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
                         void?)]
  ;; path string path -> void, checkout pin into empty staging (STEP C)
  [git-export-commit (->* (path-string? string? path-string?)
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

;; path-string -> string, directory itself as plain text
(define (dir-string d)
  (if (path? d) (path->string d) d))

;; path-string -> string, the explicit --git-dir flag value
(define (git-dir-flag d)
  (string-append "--git-dir=" (dir-string d)))

;; path-string -> (listof (cons string string))
;; Discovery stops above the target dir, so cwd inside CyberDeck never
;; resolves to the outer Subnet repo (STEP B safety).
(define (ceiling-env dir)
  `(("GIT_CEILING_DIRECTORIES" . ,(dir-string dir))))

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
;; Explicit --git-dir plus ceiling on every call (STEP B safety); only
;; creation (init) passes #:git-dir #f and relies on ceiling alone.
(define (git-run git op dir argv #:kind kind #:timeout timeout
                 #:operation operation #:git-dir [git-dir dir])
  (define full-argv
    (if git-dir (cons (git-dir-flag git-dir) argv) argv))
  (define res
    (run-command git full-argv
                 #:cwd dir
                 #:kind kind
                 #:timeout timeout
                 #:operation operation
                 #:env (append (git-env) (ceiling-env dir))))
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
                  #:operation operation #:git-dir [git-dir dir])
  (define res (git-run git op dir argv #:kind kind #:timeout timeout
                       #:operation operation #:git-dir git-dir))
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
                        #:operation "git init mirror"
                        #:git-dir #f)
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
;; Export (STEP C): checkout-based, faithful, refuses danger

;; -> path, cp for faithful tree copies (modes and links kept as links)
(define (cp-executable-path)
  (or (find-executable-path "cp")
      (raise-pm-error 'config 'git-export-commit "cp executable not found"
                      #:hint "install coreutils so export can copy trees")))

;; string path -> boolean, TARGET stays inside ROOT (absolute text)
(define (inside-root? root target)
  (define t (if (path? target) (path->string target) target))
  (or (string=? root t)
      (string-prefix? t (string-append root "/"))))

;; path path string exact-positive-integer -> void, gitlinks refused
(define (check-no-submodules git work commit timeout)
  (define res
    (git-run git 'git-export-commit work '("ls-files" "-s" "--" ".")
             #:kind 'fetch #:timeout timeout
             #:operation "git ls-files export"
             #:git-dir (build-path work ".git")))
  (if (not (zero? (run-result-exit res)))
      (raise-git-failure 'git-export-commit work "ls-files -s" res 'fetch)
      (for ([line (in-list (run-result-stdout-lines res))])
        (when (string-prefix? line "160000 ")
          (raise-pm-error 'fetch 'git-export-commit
                          "submodule in source tree"
                          #:fields `(("commit" . ,commit)
                                     ("entry" . ,line))
                          #:hint "submodules are future work, fix or wait")))))

;; path -> (or/c path #f), absolute final target or #f past 40 hops.
;; resolve-path reads one raw level here, so join relative targets
;; against each link's own directory and walk to a fixed point.
(define (resolve-fully start)
  (let loop ([current start] [n 0])
    (cond [(>= n 40) #f]
          [(link-exists? current)
           (define raw-text (path->string (resolve-path current)))
           (define parent
             (let-values ([(base _name _dir?) (split-path current)])
               base))
           (define next-text
             (if (string-prefix? raw-text "/")
                 raw-text
                 (path->string (build-path parent raw-text))))
           (loop (simplify-path (string->path next-text)) (+ n 1))]
          [else (simplify-path current)])))

;; path string -> void, every link must stay inside the staging tree.
;; Loops are refused; dangling links are refused too (broken either
;; way, and the author fix is trivial). Staging itself must be a real
;; dir, never a link (callers pass absolute scratch dirs).
(define (check-no-escaping-links staging commit)
  (when (link-exists? staging)
    (raise-pm-error 'config 'git-export-commit
                    "staging must not be a symlink"
                    #:fields `(("staging" . ,(dir-string staging)))))
  (define root (path->string (simplify-path (resolve-path staging))))
  (define (walk dir)
    (for ([entry (in-list (directory-list dir))])
      (define full (build-path dir entry))
      (cond [(link-exists? full)
             (define target (resolve-fully full))
             (cond [(not target)
                    (raise-pm-error 'fetch 'git-export-commit
                                    "symlink loop detected"
                                    #:fields `(("commit" . ,commit)
                                               ("link" . ,(dir-string full))))]
                   [(not (inside-root? root target))
                    (raise-pm-error 'fetch 'git-export-commit
                                    "symlink escapes the exported tree"
                                    #:fields `(("commit" . ,commit)
                                               ("link" . ,(dir-string full))))]
                   [(not (or (file-exists? target)
                             (directory-exists? target)))
                    (raise-pm-error 'fetch 'git-export-commit
                                    "dangling symlink in source tree"
                                    #:fields `(("commit" . ,commit)
                                               ("link" . ,(dir-string full))))]
                   [else (void)])]
            [(directory-exists? full) (walk full)]
            [else (void)])))
  (walk staging))

;; path path string path path exact-positive-integer -> void, five steps
(define (export-commit-tree git cp mirror commit work staging timeout)
  (define-values (work-parent _name _dir?) (split-path work))
  (git-run! git 'git-export-commit work-parent
            `("-c" "core.autocrlf=false"
              "-c" "core.attributesFile=/dev/null"
              "clone" "--quiet" "--no-checkout" "--"
              ,(dir-string mirror) ,(dir-string work))
            #:kind 'fetch #:timeout timeout
            #:operation "git clone export"
            #:git-dir #f)
  (git-run! git 'git-export-commit work
            `("-c" "core.autocrlf=false"
              "-c" "core.attributesFile=/dev/null"
              "checkout" "--quiet" ,commit)
            #:kind 'fetch #:timeout timeout
            #:operation "git checkout export"
            #:git-dir (build-path work ".git"))
  (check-no-submodules git work commit timeout)
  (define git-dir (build-path work ".git"))
  (when (directory-exists? git-dir)
    (delete-directory/files git-dir))
  (git-run! cp 'git-export-commit work
            `("-a" "--" ,(string-append (dir-string work) "/.")
              ,(dir-string staging))
            #:kind 'fetch #:timeout timeout
            #:operation "cp export tree"
            #:git-dir #f)
  (call-with-output-file (build-path staging ".cyberdeck-commit")
    (lambda (out) (displayln commit out)))
  (check-no-escaping-links staging commit))

;; path string path -> void, checkout pin into empty staging (STEP C)
;; Mirror untouched; work-tmp dies always; staging emptied on failure.
;; Staging should be an absolute empty dir the caller owns.
(define (git-export-commit dir commit staging #:timeout [timeout 300])
  (check-commit 'git-export-commit commit)
  (define git (git-executable-path))
  (define cp (cp-executable-path))
  (define-values (parent _name _dir?) (split-path staging))
  (unless (directory-exists? staging)
    (raise-pm-error 'config 'git-export-commit "staging dir missing"
                    #:fields `(("staging" . ,(dir-string staging)))
                    #:hint "create the empty staging dir first"))
  (unless (null? (directory-list staging))
    (raise-pm-error 'config 'git-export-commit "staging dir not empty"
                    #:fields `(("staging" . ,(dir-string staging)))
                    #:hint "export writes into an empty dir only"))
  (with-mirror-lock dir 'fetch 'git-export-commit timeout
    (lambda ()
      (unless (git-has-commit? dir commit #:timeout timeout)
        (raise-pm-error 'verify 'git-export-commit
                        "commit missing from mirror"
                        #:fields `(("commit" . ,commit)
                                   ("mirror" . ,(dir-string dir)))
                        #:hint "fetch the mirror first"))
      (define work-tmp
        (build-path parent (format ".tmp-export-~a-~a"
                                   (current-milliseconds) (gensym))))
      (define failed? #t)
      (dynamic-wind
        void
        (lambda ()
          (export-commit-tree git cp dir commit work-tmp staging timeout)
          (set! failed? #f))
        (lambda ()
          (when (directory-exists? work-tmp)
            (delete-directory/files work-tmp))
          (when failed?
            (for ([entry (in-list (directory-list staging))])
              (delete-directory/files
               (build-path staging entry)))))))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/runtime-path
           racket/string
           racket/system
           "../core/errors.rkt")

  (define git-exe (git-executable-path))
  (check-pred path-string? git-exe)
  (check-true (file-exists? git-exe))

  (define fixture-root (make-temporary-directory "pm-git~a"))
  (define fixture-home (build-path fixture-root "home"))
  (make-directory fixture-home)
  ;; CyberDeck dir: backends/ is this file's dir, its parent is the root.
  (define-runtime-path test-dir ".")
  (define-values (cyberdeck-dir _here-name _here-dir?)
    (split-path test-dir))

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

  ;; Safety (STEP B): cwd inside CyberDeck must never touch outer Subnet.
  ;; Vault under CyberDeck/tmp/ (ignored) so discovery would reach outer
  ;; without explicit --git-dir plus GIT_CEILING_DIRECTORIES.
  (parameterize ([current-allow-file-urls #t])
    (define top-res
      (run-command git-exe
                   (list "-C" (dir-string cyberdeck-dir)
                         "rev-parse" "--show-toplevel")
                   #:cwd (dir-string cyberdeck-dir)
                   #:kind 'fetch #:timeout 30
                   #:operation "test-outer-top"))
    (when (zero? (run-result-exit top-res))
      (define outer-top (car (run-result-stdout-lines top-res)))
      (define (outer-run . args)
        (run-result-stdout-lines
         (run-command git-exe (cons "-C" (cons outer-top args))
                      #:cwd (dir-string cyberdeck-dir)
                      #:kind 'fetch #:timeout 30
                      #:operation "test-outer-snapshot")))
      (define (outer-snapshot)
        (list (outer-run "rev-parse" "HEAD")
              (outer-run "status" "--porcelain")
              (outer-run "for-each-ref" "--format=%(refname)")))
      (define before (outer-snapshot))
      (define safety-vault
        (build-path cyberdeck-dir "tmp"
                    (format "pm-safety-~a" (current-milliseconds))))
      (make-directory* safety-vault)
      (define-values (safety-up safety-head)
        (make-upstream "safety-up" '(("s.txt" . "S"))))
      (parameterize ([current-directory cyberdeck-dir])
        (define smirror (vault-mirror-dir safety-vault "safety"))
        (git-clone-mirror (string-append "file://" (dir-string safety-up))
                          smirror)
        (git-fetch-mirror smirror)
        (check-true (git-has-commit? smirror safety-head))
        (git-pin-commit smirror safety-head)
        (define not-repo (build-path safety-vault "plain"))
        (make-directory not-repo)
        (check-pred fetch-error?
                    (with-handlers ([exn:fail:pm? (lambda (e) e)])
                      (git-fetch-mirror not-repo))))
      (check-equal? (outer-snapshot) before)
      (delete-directory/files safety-vault)))

  ;; Export fixtures shared by the export tests below (good tree only;
  ;; refusal branches are built inside their own tests further down).
  (define export-up (build-path fixture-root "export-up"))
  (make-directory export-up)
  (define (write-tree-text path text)
    (call-with-output-file path
      (lambda (port) (displayln text port))))
  (make-directory (build-path export-up "sub"))
  (write-tree-text (build-path export-up "a.txt") "A")
  (write-tree-text (build-path export-up "sub" "b.txt") "B")
  (write-tree-text (build-path export-up "ignored.tmp") "I")
  (write-tree-text (build-path export-up ".export-ignore") "*.tmp")
  (write-tree-text (build-path export-up "run.sh") "#!/bin/sh")
  (file-or-directory-permissions (build-path export-up "run.sh") #o755)
  (make-file-or-directory-link "a.txt" (build-path export-up "good-link"))
  (fixture-git export-up "init" "-b" "main" ".")
  (fixture-git export-up "add" "-A")
  (fixture-git export-up "commit" "-qm" "good")
  (define good-commit
    (car (run-result-stdout-lines
          (fixture-git export-up "rev-parse" "HEAD"))))
  (define export-mirror (vault-mirror-dir fixture-root "exportpkg"))
  (parameterize ([current-allow-file-urls #t])
    (git-clone-mirror (string-append "file://" (path->string export-up))
                      export-mirror))
  (check-true (git-has-commit? export-mirror good-commit))

  ;; Export success: faithful tree, pin stamp, no .git, no leftovers.
  (define staging-good (build-path fixture-root "staging-good"))
  (make-directory staging-good)
  (git-export-commit export-mirror good-commit staging-good)
  (check-true (file-exists? (build-path staging-good "a.txt")))
  (check-true (file-exists? (build-path staging-good "sub" "b.txt")))
  (check-true (file-exists? (build-path staging-good "ignored.tmp")))
  (check-true (link-exists? (build-path staging-good "good-link")))
  (check-false (directory-exists? (build-path staging-good ".git")))
  (check-equal? (file->string (build-path staging-good ".cyberdeck-commit"))
                (string-append good-commit "\n"))
  (define exec-perms
    (file-or-directory-permissions (build-path staging-good "run.sh")))
  (check-true (if (list? exec-perms)
                  (and (memq 'execute exec-perms) #t)
                  (= exec-perms #o755)))
  (check-false
   (ormap (lambda (p)
            (regexp-match? #rx"tmp-export" (path->string p)))
          (directory-list fixture-root)))
  ;; Export refusals: escaping links and submodules fail loud.
  (define outside-file (build-path fixture-root "outside.txt"))
  (write-tree-text outside-file "OUT")
  (fixture-git export-up "checkout" "-qb" "escape")
  (make-file-or-directory-link (path->string outside-file)
                               (build-path export-up "escape-link"))
  (fixture-git export-up "add" "-A")
  (fixture-git export-up "commit" "-qm" "escape")
  (define escape-commit
    (car (run-result-stdout-lines
          (fixture-git export-up "rev-parse" "HEAD"))))
  (fixture-git export-up "checkout" "-q" "main")
  (define subrepo (build-path fixture-root "subrepo"))
  (make-directory subrepo)
  (write-tree-text (build-path subrepo "s.txt") "S")
  (fixture-git subrepo "init" "-b" "main" ".")
  (fixture-git subrepo "add" "-A")
  (fixture-git subrepo "commit" "-qm" "sub-upstream")
  (fixture-git export-up "-c" "protocol.file.allow=always"
               "submodule" "add" "../subrepo" "vendor")
  (fixture-git export-up "add" "-A")
  (fixture-git export-up "commit" "-qm" "sub")
  (define sub-commit
    (car (run-result-stdout-lines
          (fixture-git export-up "rev-parse" "HEAD"))))
  (git-fetch-mirror export-mirror)
  (define staging-escape (build-path fixture-root "staging-escape"))
  (make-directory staging-escape)
  (define staging-sub (build-path fixture-root "staging-sub"))
  (make-directory staging-sub)
  (define escape-error
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (git-export-commit export-mirror escape-commit staging-escape)
      'no-error))
  (check-pred fetch-error? escape-error)
  (check-regexp-match #rx"escap" (exn-message escape-error))
  (check-equal? (directory-list staging-escape) '())
  (define sub-error
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (git-export-commit export-mirror sub-commit staging-sub)
      'no-error))
  (check-pred fetch-error? sub-error)
  (check-regexp-match #rx"submodule" (exn-message sub-error))
  ;; Export boundaries: occupied staging and unknown commits fail fast.
  (define staging-full (build-path fixture-root "staging-full"))
  (make-directory staging-full)
  (write-tree-text (build-path staging-full "sentinel.txt") "taken")
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (git-export-commit export-mirror good-commit staging-full)
                'no-error))
  (define staging-missing (build-path fixture-root "staging-missing"))
  (make-directory staging-missing)
  (define missing-error
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (git-export-commit export-mirror (make-string 40 #\b) staging-missing)
      'no-error))
  (check-pred verify-error? missing-error)
  (check-equal? (cdr (assoc "commit" (exn:fail:pm-fields missing-error)))
                (make-string 40 #\b))


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
