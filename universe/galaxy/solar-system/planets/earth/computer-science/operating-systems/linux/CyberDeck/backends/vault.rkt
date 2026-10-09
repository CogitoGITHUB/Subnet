#lang racket/base
;; vault.rkt -- the monorepo vault (D-011, D-012, docs/VAULT-SPEC.org).
;; One bare repo, per-package namespaces, try-lock writers (vault-lock),
;; lock-free readers. All git traffic runs through run-command with
;; #:cancel and #:on-progress; no timeouts anywhere (D-015). Git children
;; hold a sibling child.lock via flock so a kill -9 orphan is observable.
;; The per-package mirrors in git.rkt die with the migration; new code
;; uses only this module.

(require racket/contract/base
         racket/string
         racket/file
         racket/list
         racket/set
         "../core/errors.rkt"
         "../core/git-id.rkt"
         "../core/git-url.rkt"
         "../core/spec.rkt"
         "../core/vault-lock.rkt"
         "run.rkt"
         "manifest.rkt")

(provide
 (struct-out fetch-progress)
 (struct-out vault-add-result)
 (struct-out vault-fetch-result)
 (struct-out vault-size-report)
 (struct-out backup-push-result)
 (struct-out backup-status-entry)
 (struct-out restore-result)
 (struct-out vault-drift)
 (contract-out
  ;; string -> string, D-8 name to refs/vault/<name>
  [vault-namespace (-> string? string?)]
  ;; string string string -> void, URL change is kind 'config (D-013)
  [check-url-unchanged (-> string? string? string? void?)]
  ;; path-string -> void, bare repo plus vault config
  [vault-init (->* (path-string?)
                   (#:cancel (or/c evt? #f)
                    #:on-progress (or/c (-> fetch-progress? any/c) #f))
                   void?)]
  ;; path-string string string -> vault-add-result, fetch plus pin
  [vault-add (->* (path-string? string? string?)
                  (#:pin (or/c #f string?)
                   #:cancel (or/c evt? #f)
                   #:on-progress (or/c (-> fetch-progress? any/c) #f)
                   #:holder (or/c #f string?)
                   #:fsck-allow (listof string?))
                  vault-add-result?)]
  ;; path-string -> (listof string), namespaces present, sorted
  [vault-list (-> path-string? (listof string?))]
  ;; path-string -> vault-size-report, objects plus ref counts
  [vault-size (-> path-string? vault-size-report?)]
  ;; path-string string string -> vault-fetch-result, refetch namespace
  [vault-fetch-namespace
   (->* (path-string? string? string?)
        (#:cancel (or/c evt? #f)
         #:on-progress (or/c (-> fetch-progress? any/c) #f)
         #:holder (or/c #f string?)
         #:fsck-allow (listof string?))
        vault-fetch-result?)]
  ;; path-string -> void, integrity check, kind 'verify on failure
  [vault-verify (->* (path-string?) (#:full boolean?) void?)]
  ;; path-string -> void, explicit pack with bounded memory
  [vault-gc (->* (path-string?)
                 (#:cancel (or/c evt? #f)
                  #:on-progress (or/c (-> fetch-progress? any/c) #f)
                  #:holder (or/c #f string?))
                 void?)]
  ;; path-string string string -> backup-push-result, one namespace
  [vault-backup-push
   (->* (path-string? string? string?)
        (#:allow-large? boolean?
         #:cancel (or/c evt? #f)
         #:on-progress (or/c (-> fetch-progress? any/c) #f)
         #:holder (or/c #f string?))
        backup-push-result?)]
  ;; path-string string string -> (listof backup-status-entry?)
  [vault-backup-status
   (-> path-string? string? string? (listof backup-status-entry?))]
  ;; path-string string string -> restore-result, rebuild from backup
  [vault-restore
   (->* (path-string? string? string?)
        (#:cancel (or/c evt? #f)
         #:on-progress (or/c (-> fetch-progress? any/c) #f)
         #:holder (or/c #f string?))
        restore-result?)]
  ;; path-string path-string -> (listof vault-drift?), manifest vs refs
  [vault-status
   (-> path-string? path-string? (listof vault-drift?))]
  ;; path-string string string path-string -> void, pin to empty staging
  [vault-export-commit
   (->* (path-string? string? string? path-string?)
        (#:cancel (or/c evt? #f)
         #:on-progress (or/c (-> fetch-progress? any/c) #f))
        void?)]))

(struct fetch-progress (phase percent bytes) #:transparent)
;; phase   : string?  lowercased git phase (receiving, counting, ...)
;; percent : (or/c exact-nonnegative-integer? #f)
;; bytes   : (or/c exact-nonnegative-integer? #f)

(struct vault-add-result
  (name namespace pin pin-source refs-created superseded
   gone-upstream warnings size-before size-after)
  #:transparent)
;; pin-source : (or/c 'given 'remote-head)

(struct vault-size-report (bytes objects loose-refs packed-refs)
  #:transparent)

(struct vault-fetch-result
  (name namespace refs-created superseded gone-upstream warnings
   size-before size-after)
  #:transparent)

;; ---------------------------------------------------------------------------
;; Names (D-8; namespaces are derived, never passed in)

;; string -> string, refs/vault/<name> or kind 'spec
(define (vault-namespace name)
  (unless (and (string? name)
               (package-name? (string->symbol name)))
    (raise-pm-error 'spec 'vault-namespace "invalid package name"
                    #:fields `(("name" . ,name))))
  (string-append "refs/vault/" name))

;; string string string -> void, changed URL is kind 'config (D-013 open)
(define (check-url-unchanged name recorded-url new-url)
  (unless (equal? recorded-url new-url)
    (raise-pm-error 'config 'check-url-unchanged "package URL changed"
                    #:fields `(("package" . ,name)
                               ("recorded" . ,recorded-url)
                               ("new" . ,new-url))
                    #:hint "see D-013; no replace option in v1")))

;; ---------------------------------------------------------------------------
;; Spawning git under flock (orphan-safe children)

;; path-string -> string, plain text of a path
(define (dir-string d)
  (if (path? d) (path->string d) d))

;; path-string -> path, parent dir that must exist (cwd for git)
(define (vault-cwd vault-root)
  (define-values (base _name _dir?) (split-path (simplify-path vault-root)))
  (if (path? base) base (current-directory)))

;; path-string -> path, sibling lock held by every git child
(define (vault-child-lock vault-root)
  (build-path (vault-cwd vault-root) "child.lock"))

;; path-string -> (listof (cons string string)), isolated env
(define (vault-env vault-root)
  `(("GIT_CONFIG_NOSYSTEM" . "1")
    ("GIT_CONFIG_GLOBAL"
     . ,(path->string (build-path (find-system-path 'home-dir)
                                  ".config" "cyberdeck" "gitconfig")))
    ("GIT_TERMINAL_PROMPT" . "0")
    ("GIT_CEILING_DIRECTORIES" . ,(dir-string (vault-cwd vault-root)))))

;; string -> (or/c fetch-progress #f), one git progress line or #f
(define progress-rx
  #rx"(?i:(receiving|resolving|enumerating|counting|compressing)[^0-9%]*)([0-9]+)%")
(define progress-bytes-rx #rx"([0-9]+(?:\\.[0-9]+)?) ([KMGT]iB)")

(define (progress-bytes line)
  (define m (regexp-match progress-bytes-rx line))
  (and m
       (inexact->exact (round (* (string->number (cadr m))
                       (cond [(equal? (caddr m) "KiB") 1024]
                             [(equal? (caddr m) "MiB") 1048576]
                             [(equal? (caddr m) "GiB") 1073741824]
                             [(equal? (caddr m) "TiB") 1099511627776]
                             [else 1]))))))

(define (parse-progress-line line)
  (define m (and (string? line) (regexp-match progress-rx line)))
  (and m
       (fetch-progress (string-downcase (cadr m))
                       (string->number (caddr m))
                       (progress-bytes line))))

;; path-string (listof string) -> run-result, flock-held git child.
;; #:git-dir #f only for creation (init); every URL/path takes -- first
;; at the call site. Locking the child means a kill -9 orphan keeps
;; child.lock held, which writers observe (needs-verify).
(define (vault-git vault-root argv
                   #:op op
                   #:kind [kind 'fetch]
                   #:operation [operation "git operation"]
                   #:cancel [cancel #f]
                   #:on-progress [on-progress #f]
                   #:git-dir [git-dir #t])
  (define git
    (or (find-executable-path "git")
        (raise-pm-error 'config op "git executable not found"
                        #:hint "install git so the package manager can fetch")))
  (define flock-exe
    (or (find-executable-path "flock")
        (raise-pm-error 'config op "flock executable not found"
                        #:hint "install flock so vault children are orphan-safe")))
  (define git-argv
    (append '("-c" "protocol.ext.allow=never")
            (cond [(eq? git-dir #t)
                   (list (string-append "--git-dir="
                                        (dir-string vault-root)))]
                  [(not git-dir) '()]
                  [else (list (string-append "--git-dir="
                                             (dir-string git-dir)))])
            argv))
  (run-command flock-exe
               (cons (dir-string (vault-child-lock vault-root))
                     (cons (path->string git) git-argv))
               #:cwd (vault-cwd vault-root)
               #:kind kind
               #:operation operation
               #:env (vault-env vault-root)
               #:cancel cancel
               #:on-progress (and on-progress
                                  (lambda (line)
                                    (define p (parse-progress-line line))
                                    (when p (on-progress p))))))

;; symbol path-string run-result string -> never returns (E-8 fields)
(define (raise-git-failure op vault-root command res kind)
  (raise-pm-error kind op "git command failed"
                  #:fields `(("vault" . ,(dir-string vault-root))
                             ("command" . ,command)
                             ("exit-code"
                              . ,(number->string (run-result-exit res)))
                             ("stderr" . ,(string-join
                                           (run-result-stderr-lines res)
                                           "\n")))))

;; path-string symbol string run-result pm-kind -> void, nonzero raises
(define (vault-git! vault-root op argv res kind command)
  (unless (zero? (run-result-exit res))
    (raise-git-failure op vault-root command res kind)))

;; ---------------------------------------------------------------------------
;; Reading refs

;; path-string string -> (hash/c string? string?), refname to sha
(define (vault-refmap vault-root ns)
  (define res
    (vault-git vault-root
               `("for-each-ref" "--format=%(refname)%00%(objectname)"
                 "--" ,ns)
               #:op 'vault-refmap #:kind 'internal
               #:operation "list namespace refs"))
  (vault-git! vault-root 'vault-refmap '("for-each-ref") res 'internal
              "for-each-ref")
  (for/hash ([line (in-list (run-result-stdout-lines res))]
             #:when (regexp-match? #rx"\0" line))
    (define parts (string-split line "\0"))
    (values (car parts) (cadr parts))))

;; (hash/c string? string?) -> (hash/c string? string?), heads+tags only
(define (tips-only refmap ns)
  (for/hash ([(r sha) (in-hash refmap)]
             #:when (or (string-prefix? r (string-append ns "/heads/"))
                        (string-prefix? r (string-append ns "/tags/"))))
    (values r sha)))

;; ---------------------------------------------------------------------------
;; Init

(define vault-init-config
  '(("core.logAllRefUpdates" . "always")
    ("gc.auto" . "0")
    ("maintenance.auto" . "false")
    ("gc.reflogExpire" . "never")
    ("gc.reflogExpireUnreachable" . "never")
    ("gc.pruneExpire" . "never")
    ("transfer.fsckObjects" . "true")
    ("fetch.prune" . "false")
    ("fetch.pruneTags" . "false")))

;; path-string -> void, bare repo plus config, no remote.* ever
(define (vault-init vault-root
                    #:cancel [cancel #f]
                    #:on-progress [on-progress #f])
  (define parent (vault-cwd vault-root))
  (unless (directory-exists? parent)
    (raise-pm-error 'config 'vault-init "vault parent missing"
                    #:fields `(("parent" . ,(dir-string parent)))))
  (define res
    (vault-git vault-root
               `("init" "--bare" "--template=" "--" ,(dir-string vault-root))
               #:op 'vault-init #:kind 'config
               #:operation "init bare vault" #:cancel cancel
               #:on-progress on-progress #:git-dir #f))
  (vault-git! vault-root 'vault-init '("init") res 'config "init")
  (for ([kv (in-list vault-init-config)])
    (define r
      (vault-git vault-root `("config" ,(car kv) ,(cdr kv))
                 #:op 'vault-init #:kind 'config
                 #:operation "configure vault"))
    (vault-git! vault-root 'vault-init '("config") r 'config "config"))
  (define remotes
    (vault-git vault-root '("config" "--get-regexp" "^remote\\.")
               #:op 'vault-init #:kind 'config
               #:operation "check no remotes"))
  (when (zero? (run-result-exit remotes))
    (raise-pm-error 'config 'vault-init "vault has remote config"
                    #:fields `(("detail" . ,(string-join
                                              (run-result-stdout-lines remotes)
                                              "\n")))
                    #:hint "no remote.* config ever; URLs live in the manifest")))

;; path-string -> void, missing vault is kind 'config
(define (ensure-vault vault-root)
  (define res
    (vault-git vault-root '("rev-parse" "--is-bare-repository")
               #:op 'ensure-vault #:kind 'config
               #:operation "check vault present"))
  (unless (and (zero? (run-result-exit res))
               (equal? (run-result-stdout-lines res) '("true")))
    (raise-pm-error 'config 'ensure-vault "vault not initialized"
                    #:fields `(("vault" . ,(dir-string vault-root)))
                    #:hint "run vault-init first")))

;; path-string -> void, held child.lock refuses writers (needs-verify)
(define (vault-assert-child-free vault-root)
  (define flock-exe
    (or (find-executable-path "flock")
        (raise-pm-error 'config 'vault-add "flock executable not found"
                        #:hint "install flock so vault children are orphan-safe")))
  (define true-exe
    (or (find-executable-path "true")
        (raise-pm-error 'config 'vault-add "true executable not found"
                        #:hint "install coreutils so the lock probe can run")))
  (define res
    (run-command flock-exe
                 (list "-n" (dir-string (vault-child-lock vault-root))
                       (path->string true-exe))
                 #:cwd (vault-cwd vault-root)
                 #:kind 'config
                 #:operation "probe child lock"
                 #:env (vault-env vault-root)))
  (unless (zero? (run-result-exit res))
    (raise-pm-error 'config 'vault-add "vault needs verify"
                    #:fields `(("vault" . ,(dir-string vault-root)))
                    #:hint "a git child may be orphaned; wait for it or run pm vault verify")))

;; ---------------------------------------------------------------------------
;; Writing refs

;; path-string string string -> void, create or move one ref
(define (vault-set-ref vault-root ref sha)
  (define res
    (vault-git vault-root `("update-ref" "--" ,ref ,sha)
               #:op 'vault-set-ref #:kind 'internal
               #:operation "write ref"))
  (vault-git! vault-root 'vault-set-ref '("update-ref") res 'internal
              "update-ref"))

;; path-string string -> void, delete one ref
(define (vault-delete-ref vault-root ref)
  (define res
    (vault-git vault-root `("update-ref" "-d" "--" ,ref)
               #:op 'vault-delete-ref #:kind 'internal
               #:operation "delete ref"))
  (vault-git! vault-root 'vault-delete-ref '("update-ref") res 'internal
              "update-ref -d"))

;; path-string -> void, pack all refs (ends every add path)
(define (vault-pack-refs vault-root)
  (define res
    (vault-git vault-root '("pack-refs" "--all")
               #:op 'vault-pack-refs #:kind 'internal
               #:operation "pack refs"))
  (vault-git! vault-root 'vault-pack-refs '("pack-refs") res 'internal
              "pack-refs --all"))

;; ---------------------------------------------------------------------------
;; Fetch

;; path-string string string (listof string) evt/#f proc/#f -> run-result
;; path-string string string (listof string) evt/#f proc/#f -> run-result.
;; #:refspecs replaces the default heads+tags pair (restore fetches
;; pinned and superseded too, never with remote-head).
(define (vault-fetch-run vault-root url ns fsck-allow cancel on-progress
                         #:refspecs [refspecs #f])
  (vault-git vault-root
             (append (append-map (lambda (id)
                                   (list "-c"
                                         (string-append "fsck." id "=ignore")))
                                 fsck-allow)
                     (list "fetch" "--progress" "--no-tags"
                           "--no-write-fetch-head"
                           "--" url)
                     (or refspecs
                         (list (string-append "+refs/heads/*:" ns "/heads/*")
                               (string-append "+refs/tags/*:" ns "/tags/*"))))
             #:op 'vault-add #:kind 'fetch
             #:operation "fetch namespace"
             #:cancel cancel #:on-progress on-progress))

;; string string -> boolean, path collision at a / boundary (not equal)
(define (ref-collides? a b)
  (and (not (equal? a b))
       (or (string-prefix? b (string-append a "/"))
           (string-prefix? a (string-append b "/")))))

;; path-string string string (hash/c string? string?) -> (listof string),
;; our refs colliding with upstream names (both directions)
(define (vault-df-collisions vault-root ns url before)
  (define advertised
    (with-handlers ([exn:fail:pm? (lambda (_) '())])
      (vault-advertised vault-root url)))
  (define ours
    (for/list ([r (in-hash-keys before)]
               #:when (or (string-prefix? r (string-append ns "/heads/"))
                          (string-prefix? r (string-append ns "/tags/"))))
      r))
  (define (short-of r)
    (define m (regexp-match #rx"refs/vault/[^/]+/(heads|tags)/(.+)$" r))
    (and m (string-append (cadr m) "/" (caddr m))))
  (for/list ([r (in-list ours)]
             #:when (let ((s (short-of r)))
                      (and s (ormap (lambda (a) (ref-collides? s a))
                                    advertised))))
    r))

;; path-string string string string -> (values string string), rescue+warn.
;; With #:delete? the stale ref itself goes too (D/F retry, where the
;; fetch has not run yet). After a fetch the ref already moved, so only
;; the rescue ref is created and the new tip stays.
(define (vault-rescue-ref vault-root ns ref sha #:delete? [delete? #t])
  (define kind
    (cond [(string-prefix? ref (string-append ns "/heads/")) "heads"]
          [(string-prefix? ref (string-append ns "/tags/")) "tags"]
          [else (raise-pm-error 'internal 'vault-rescue-ref
                                "ref outside heads/tags"
                                #:fields (list (cons "ref" ref)))]))
  (define short (substring ref (+ (string-length ns)
                                  (string-length kind) 2)))
  (define sup (string-append ns "/superseded/" sha "/" kind "/" short))
  (vault-set-ref vault-root sup sha)
  (when delete?
    (vault-delete-ref vault-root ref))
  (values sup
          (format "moved stale ~a under ~a (ref conflict)" ref sup)))

;; ---------------------------------------------------------------------------
;; Add

;; path-string string -> string, upstream HEAD sha or kind 'fetch
(define (vault-resolve-head vault-root url)
  (define res
    (vault-git vault-root `("ls-remote" "--" ,url "HEAD")
               #:op 'vault-add #:kind 'fetch
               #:operation "resolve remote HEAD"))
  (vault-git! vault-root 'vault-add '("ls-remote") res 'fetch "ls-remote")
  (define lines (run-result-stdout-lines res))
  (define m (and (pair? lines) (regexp-match #rx"^([0-9a-f]+)\tHEAD" (car lines))))
  (unless m
    (raise-pm-error 'fetch 'vault-add "empty remote or unresolvable HEAD"
                    #:fields `(("url" . ,url))))
  (cadr m))

;; path-string string -> (listof string), advertised branch/tag names
(define (vault-advertised vault-root url)
  (define res
    (vault-git vault-root `("ls-remote" "--heads" "--tags" "--" ,url)
               #:op 'vault-add #:kind 'fetch
               #:operation "list upstream refs"))
  (vault-git! vault-root 'vault-add '("ls-remote") res 'fetch "ls-remote")
  (for/list ([line (in-list (run-result-stdout-lines res))]
             #:when (regexp-match? #rx"\trefs/(heads|tags)/" line)
             #:unless (string-suffix? line "^{}"))
    (define m (regexp-match #rx"\trefs/(heads|tags)/(.+)$" line))
    (string-append (cadr m) "/" (caddr m))))

;; path-string string string string -> void, pin on a tip or kind 'fetch
(define (vault-assert-reachable vault-root ns pin url)
  (define tips (tips-only (vault-refmap vault-root ns) ns))
  (define ok?
    (for/or ([tip (in-hash-values tips)])
      (define res
        (vault-git vault-root `("merge-base" "--is-ancestor" "--" ,pin ,tip)
                   #:op 'vault-add #:kind 'fetch
                   #:operation "check pin reachability"))
      (zero? (run-result-exit res))))
  (unless ok?
    (raise-pm-error 'fetch 'vault-add "pin not on any branch or tag"
                    #:fields `(("commit" . ,pin) ("url" . ,url))
                    #:hint "upstream may have rewritten history, see D-013")))

;; path-string string (hash/c string? string?) -> (values (listof string) (listof string))
(define (vault-supersede-moves vault-root ns before)
  (define after (tips-only (vault-refmap vault-root ns) ns))
  (define sups '())
  (define warns '())
  (for ([(r new) (in-hash after)]
        #:when (and (hash-has-key? before r)
                    (not (equal? (hash-ref before r) new))))
    (let* ((old (hash-ref before r))
           (ff? (vault-git vault-root `("merge-base" "--is-ancestor" "--"
                                        ,old ,new)
                          #:op 'vault-add #:kind 'fetch
                          #:operation "check fast-forward")))
      (unless (zero? (run-result-exit ff?))
        (let-values ([(sup warn)
                      (vault-rescue-ref vault-root ns r old
                                        #:delete? #f)])
          (set! sups (cons sup sups))
          (set! warns (cons (string-append warn " (non-fast-forward)")
                            warns))))))
  (values (reverse sups) (reverse warns)))

;; path-string string (hash/c string? string?) -> void, delete created only
(define (vault-add-rollback vault-root ns before)
  (define after (vault-refmap vault-root ns))
  (for ([r (in-hash-keys after)]
        #:unless (hash-has-key? before r))
    (vault-delete-ref vault-root r))
  (vault-pack-refs vault-root))

;; path-string string string (listof string) evt/#f proc/#f
;; (hash/c string? string?) -> (listof string), fetch plus one D/F
;; rescue+retry; raises on failure (count-bounded: at most two fetches)
(define (vault-fetch-with-retry vault-root url ns fsck-allow cancel
                                on-progress before
                                #:refspecs [refspecs #f])
  (define res (vault-fetch-run vault-root url ns fsck-allow cancel
                               on-progress #:refspecs refspecs))
  (define warns '())
  (define fetch-failed? (not (zero? (run-result-exit res))))
  (define collisions
    (and fetch-failed?
         (vault-df-collisions vault-root ns url before)))
  (cond [(not fetch-failed?) warns]
        [(null? collisions)
         (vault-git! vault-root 'vault-fetch '("fetch") res 'fetch "fetch")]
        [else
         (for ([r (in-list collisions)])
           (let-values ([(sup warn)
                         (vault-rescue-ref vault-root ns r
                                           (hash-ref before r))])
             (set! warns (cons warn warns))))
         (let ((retry (vault-fetch-run vault-root url ns fsck-allow
                                       cancel on-progress)))
           (unless (zero? (run-result-exit retry))
             (vault-git! vault-root 'vault-fetch '("fetch") retry
                         'fetch "fetch"))
           (set! warns (cons "retried fetch after ref rescue" warns))
           warns)]))

;; path-string string string (hash/c string? string?)
;; -> (values (listof string) (listof string)), short names under heads|tags
(define (vault-gone-upstream vault-root url ns)
  (define advertised (vault-advertised vault-root url))
  (define ours
    (for/list ([r (in-hash-keys (tips-only (vault-refmap vault-root ns)
                                           ns))])
      (let ((m (regexp-match #rx"refs/vault/[^/]+/(heads|tags)/(.+)$" r)))
        (string-append (cadr m) "/" (caddr m)))))
  (sort (for/list ([o (in-list ours)]
                   #:unless (member o advertised))
          o)
        string<?))

;; path-string string string (hash/c string? string?)
;; -> (values (listof string) (listof string) (listof string)),
;; supersede moves, gone-upstream scan, then pack (shared tail)
(define (vault-refresh-tail vault-root url ns before)
  (define-values (sups warns) (vault-supersede-moves vault-root ns before))
  (define gone (vault-gone-upstream vault-root url ns))
  (vault-pack-refs vault-root)
  (values sups warns gone))

;; path-string string string string (or/c #f string?) ... -> vault-add-result
(define (vault-add-locked vault-root name url ns pin cancel on-progress
                          fsck-allow)
  (vault-assert-child-free vault-root)
  (define size-before (vault-size vault-root))
  (define before (vault-refmap vault-root ns))
  (define-values (gone warnings pin*)
    (with-handlers ([exn:fail:pm?
                     (lambda (e)
                       (vault-add-rollback vault-root ns before)
                       (raise e))])
      (define warns (vault-fetch-with-retry vault-root url ns
                                                  fsck-allow cancel
                                                  on-progress before))
      (define pin* (or pin (vault-resolve-head vault-root url)))
      (unless pin
        (vault-set-ref vault-root (string-append ns "/remote-head") pin*))
      (vault-assert-reachable vault-root ns pin* url)
      (vault-set-ref vault-root
                     (string-append ns "/pinned/" pin*) pin*)
      (define-values (sups warns2 gone-upstream)
        (vault-refresh-tail vault-root url ns before))
      (values gone-upstream (append warns warns2) pin*)))
  (define after (vault-refmap vault-root ns))
  (define created
    (sort (for/list ([r (in-hash-keys after)]
                     #:unless (hash-has-key? before r))
            r)
          string<?))
  (vault-add-result name ns pin* (if pin 'given 'remote-head) created
                    (for/list ([r (in-list created)]
                               #:when (string-prefix?
                                       r (string-append ns "/superseded/")))
                      r)
                    gone warnings size-before (vault-size vault-root)))

;; path-string string string -> vault-add-result, validated plus locked
(define (vault-add vault-root name url
                   #:pin [pin #f]
                   #:cancel [cancel #f]
                   #:on-progress [on-progress #f]
                   #:holder [holder #f]
                   #:fsck-allow [fsck-allow '()])
  (define ns (vault-namespace name))
  (check-git-url url)
  (when pin
    (unless (git-id? pin)
      (raise-pm-error 'spec 'vault-add "not a commit id"
                      #:fields `(("value" . ,pin)))))
  (for ([id (in-list fsck-allow)])
    (unless (and (string? id)
                 (regexp-match? #rx"^[a-zA-Z][a-zA-Z0-9]*$" id))
      (raise-pm-error 'spec 'vault-add "bad fsck message id"
                      #:fields `(("value" . ,id)))))
  ;; Probe BEFORE any spawn: ensure-vault and every vault-git call run
  ;; through blocking flock, so a live holder would wedge the spawn
  ;; forever and the test thread would never reach the release.
  ;; Failing fast here breaks that triangle (design: writers refuse).
  (vault-assert-child-free vault-root)
  (ensure-vault vault-root)
  (call-with-vault-lock vault-root (or holder "interactive")
                        (format "add ~a" name)
    (lambda ()
      (vault-add-locked vault-root name url ns pin cancel on-progress
                        fsck-allow))))

;; path-string string string -> vault-fetch-result, refetch plus hygiene
(define (vault-fetch-namespace vault-root name url
                               #:cancel [cancel #f]
                               #:on-progress [on-progress #f]
                               #:holder [holder #f]
                               #:fsck-allow [fsck-allow '()])
  (define ns (vault-namespace name))
  (check-git-url url)
  (for ([id (in-list fsck-allow)])
    (unless (and (string? id)
                 (regexp-match? #rx"^[a-zA-Z][a-zA-Z0-9]*$" id))
      (raise-pm-error 'spec 'vault-fetch-namespace "bad fsck message id"
                      #:fields `(("value" . ,id)))))
  (vault-assert-child-free vault-root)
  (ensure-vault vault-root)
  (call-with-vault-lock vault-root (or holder "interactive")
                        (format "fetch ~a" name)
    (lambda ()
      (define size-before (vault-size vault-root))
      (define before (vault-refmap vault-root ns))
      (define-values (gone warnings sups)
        (with-handlers ([exn:fail:pm?
                         (lambda (e)
                           (vault-add-rollback vault-root ns before)
                           (raise e))])
          (define fetch-warns
            (vault-fetch-with-retry vault-root url ns fsck-allow cancel
                                    on-progress before))
          (define-values (rescue-supers rescue-warns gone-upstream)
            (vault-refresh-tail vault-root url ns before))
          (values gone-upstream (append fetch-warns rescue-warns)
                  rescue-supers)))
      (define after (vault-refmap vault-root ns))
      (define created
        (sort (for/list ([r (in-hash-keys after)]
                         #:unless (hash-has-key? before r))
                r)
              string<?))
      (vault-fetch-result name ns created sups gone warnings
                          size-before (vault-size vault-root)))))

;; path-string -> void, integrity check, kind 'verify on failure
(define (vault-verify vault-root #:full [full #f])
  (ensure-vault vault-root)
  (define res
    (vault-git vault-root (if full '("fsck" "--full")
                              '("fsck" "--connectivity-only"))
               #:op 'vault-verify #:kind 'verify
               #:operation "verify vault"))
  (unless (zero? (run-result-exit res))
    (raise-pm-error 'verify 'vault-verify "vault fsck failed"
                    #:fields `(("vault" . ,(dir-string vault-root))
                               ("detail" . ,(string-join
                                              (run-result-stderr-lines res)
                                              "\n"))))))

;; path-string -> void, explicit pack with bounded memory
(define (vault-gc vault-root
                  #:cancel [cancel #f]
                  #:on-progress [on-progress #f]
                  #:holder [holder #f])
  (vault-assert-child-free vault-root)
  (ensure-vault vault-root)
  (call-with-vault-lock vault-root (or holder "interactive")
                        "gc vault"
    (lambda ()
      (define res
        (vault-git vault-root '("-c" "pack.threads=1"
                                "-c" "pack.windowMemory=256m"
                                "gc" "--quiet")
                   #:op 'vault-gc #:kind 'build
                   #:operation "collect vault garbage"
                   #:cancel cancel #:on-progress on-progress))
      (unless (zero? (run-result-exit res))
        (raise-pm-error 'build 'vault-gc "vault gc failed"
                        #:fields `(("vault" . ,(dir-string vault-root))
                                   ("detail" . ,(string-join
                                                  (run-result-stderr-lines res)
                                                  "\n"))))))))

;; path-string string string path-string -> void, pin to empty staging.
;; Same contract as git-export-commit: staging exists and is empty,
;; faithful file list, staging cleaned on failure, vault never written.
(define (vault-export-commit vault-root name pin staging
                             #:cancel [cancel #f]
                             #:on-progress [on-progress #f])
  (define ns (vault-namespace name))
  (unless (git-id? pin)
    (raise-pm-error 'spec 'vault-export-commit "not a commit id"
                    #:fields (list (cons "value" pin))))
  (unless (directory-exists? staging)
    (raise-pm-error 'config 'vault-export-commit "staging dir missing"
                    #:fields (list (cons "staging" (dir-string staging)))
                    #:hint "create the empty staging dir first"))
  (unless (null? (directory-list staging))
    (raise-pm-error 'config 'vault-export-commit "staging dir not empty"
                    #:fields (list (cons "staging" (dir-string staging)))
                    #:hint "export writes into an empty dir only"))
  (ensure-vault vault-root)
  (define present?
    (vault-git vault-root (list "cat-file" "-e" pin)
               #:op 'vault-export-commit #:kind 'verify
               #:operation "check pin present"
               #:cancel cancel #:on-progress on-progress))
  (unless (zero? (run-result-exit present?))
    (raise-pm-error 'verify 'vault-export-commit "commit missing from vault"
                    #:fields (list (cons "commit" pin)
                                   (cons "namespace" ns))))
  (define tar
    (or (find-executable-path "tar")
        (raise-pm-error 'config 'vault-export-commit "tar executable not found"
                        #:hint "install tar so exports can unpack archives")))
  (define-values (parent _name _dir?) (split-path (simplify-path staging)))
  (define tar-tmp
    (build-path parent
                (string-append ".tmp-export-"
                               (symbol->string (gensym 'vault))
                               ".tar")))
  (define failed? #t)
  (dynamic-wind
    void
    (lambda ()
      (define tree-res
        (vault-git vault-root (list "ls-tree" "-r" pin)
                   #:op 'vault-export-commit #:kind 'fetch
                   #:operation "list export tree"
                   #:cancel cancel #:on-progress on-progress))
      (vault-git! vault-root 'vault-export-commit '("ls-tree") tree-res
                  'fetch "ls-tree")
      (for ([line (in-list (run-result-stdout-lines tree-res))])
        (when (regexp-match? #rx"^160000 " line)
          (raise-pm-error 'fetch 'vault-export-commit "submodules refused"
                          #:fields (list (cons "commit" pin)))))
      (define archive-res
        (vault-git vault-root (list "archive" "--format=tar" "--output"
                                    (dir-string tar-tmp) pin)
                   #:op 'vault-export-commit #:kind 'fetch
                   #:operation "write export archive"
                   #:cancel cancel #:on-progress on-progress))
      (vault-git! vault-root 'vault-export-commit '("archive") archive-res
                  'fetch "archive")
      (define untar-res
        (run-command tar (list "-x" "-f" (dir-string tar-tmp)
                               "-C" (dir-string staging))
                     #:cwd (dir-string parent)
                     #:kind 'fetch #:operation "unpack export tree"
                     #:env (vault-env vault-root)
                     #:cancel cancel #:on-progress on-progress))
      (unless (zero? (run-result-exit untar-res))
        (raise-pm-error 'fetch 'vault-export-commit "unpack failed"
                        #:fields (list (cons "staging"
                                             (dir-string staging)))))
      (set! failed? #f))
    (lambda ()
      (when (file-exists? tar-tmp)
        (delete-file tar-tmp))
      (when failed?
        (for ([entry (in-list (directory-list staging))])
          (delete-directory/files (build-path staging entry)))))))
(define (vault-list vault-root)
  (ensure-vault vault-root)
  (define res
    (vault-git vault-root '("for-each-ref" "--format=%(refname)")
               #:op 'vault-list #:kind 'internal
               #:operation "list namespaces"))
  (vault-git! vault-root 'vault-list '("for-each-ref") res 'internal
              "for-each-ref")
  (sort (remove-duplicates
         (for/list ([line (in-list (run-result-stdout-lines res))]
                    #:when (regexp-match? #rx"^refs/vault/" line))
           (cadr (regexp-match #rx"^refs/vault/([^/]+)/" line))))
        string<?))

;; path-string -> vault-size-report, objects plus ref counts
(define (vault-size vault-root)
  (ensure-vault vault-root)
  (define res
    (vault-git vault-root '("count-objects" "-v")
               #:op 'vault-size #:kind 'internal
               #:operation "count objects"))
  (vault-git! vault-root 'vault-size '("count-objects") res 'internal
              "count-objects -v")
  (define kv
    (for/hash ([line (in-list (run-result-stdout-lines res))]
               #:when (regexp-match? #rx": " line))
      (define parts (regexp-match #rx"^([^:]+): (.+)$" line))
      (values (car parts) (string->number (cadr parts)))))
  (define (get k) (hash-ref kv k 0))
  (define refs (vault-refmap vault-root "refs/vault"))
  (define packed-file (build-path (dir-string vault-root) "packed-refs"))
  (define packed
    (if (file-exists? packed-file)
        (length (for/list ([line (in-list (file->lines packed-file))]
                           #:when (regexp-match? #rx"^[0-9a-f]+ refs/vault/" line))
                  line))
        0))
  (define total (hash-count refs))
  (vault-size-report (* (+ (get "size") (get "size-pack")) 1024)
                     (+ (get "count") (get "in-pack"))
                     (- total packed) packed))

;; ---------------------------------------------------------------------------
;; ---------------------------------------------------------------------------
;; Backup, restore, status (one namespace per call, resumable)

(struct backup-push-result (name ok? reason pushed-refs) #:transparent)
(struct backup-status-entry (name ref local backup state) #:transparent)
(struct restore-result (name ok? reason refs-restored) #:transparent)
(struct vault-drift (kind detail) #:transparent)

;; path-string string -> (listof string), "sha bytes" over 100MB
(define (vault-large-blobs vault-root ns)
  (define tips
    (vault-tip-shas vault-root ns))
  (define revs
    (if (null? tips)
        '()
        (vault-rev-objects vault-root tips)))
  (define batch
    (vault-git vault-root '("cat-file" "--batch-check" "--batch-all-objects")
               #:op 'vault-large-blobs #:kind 'internal
               #:operation "size all objects"))
  (vault-git! vault-root 'vault-large-blobs '("cat-file") batch 'internal
              "cat-file")
  (define reachable
    (if (or (null? revs) (not revs))
        (list->seteqv '())
        (list->seteqv
         (for/list ([line (in-list (run-result-stdout-lines revs))]
                    #:when (regexp-match? #rx"^[0-9a-f]{40}( |$)" line))
           (car (string-split line " "))))))
  (define big
    (for/list ([line (in-list (run-result-stdout-lines batch))]
               #:when (vault-big-line? line reachable))
      (car (string-split line " "))))
  big)

;; path-string string -> (listof string), tip shas under a namespace
(define (vault-tip-shas vault-root ns)
  (define res
    (vault-git vault-root `("for-each-ref" "--format=%(objectname)"
                            "--" ,ns)
               #:op 'vault-large-blobs #:kind 'internal
               #:operation "list namespace tips"))
  (vault-git! vault-root 'vault-large-blobs '("for-each-ref") res 'internal
              "for-each-ref")
  (run-result-stdout-lines res))

;; path-string (listof string) -> (or/c #f run-result?), objects or #f
(define (vault-rev-objects vault-root tips)
  (if (null? tips)
      #f
      (let ((res (vault-git vault-root (append (list "rev-list" "--objects")
                                               tips)
                            #:op 'vault-large-blobs #:kind 'internal
                            #:operation "list namespace objects")))
        (vault-git! vault-root 'vault-large-blobs '("rev-list") res 'internal
                    "rev-list")
        res)))

;; string (set/c string?) -> (or/c #f string?), sha when big+reachable
(define (vault-big-line? line reachable)
  (define m (regexp-match #rx"^([0-9a-f]+) blob ([0-9]+)$" line))
  (and m
       (> (string->number (caddr m)) 100000000)
       (set-member? reachable (cadr m))
       (cadr m)))
;; path-string string string -> backup-push-result, heads+tags forced
(define (vault-backup-push vault-root name remote-url
                           #:allow-large? [allow-large? #f]
                           #:cancel [cancel #f]
                           #:on-progress [on-progress #f]
                           #:holder [holder #f])
  (define ns (vault-namespace name))
  (check-git-url remote-url)
  (ensure-vault vault-root)
  (define big (vault-large-blobs vault-root ns))
  (unless (or (null? big) allow-large?)
    (raise-pm-error 'config 'vault-backup-push "namespace holds large blobs"
                    #:fields (list (cons "name" name)
                                   (cons "blobs" (string-join big " ")))
                    #:hint "re-run with #:allow-large? #t and record it in the manifest"))
  (vault-assert-child-free vault-root)
  (call-with-vault-lock vault-root (or holder "interactive")
                        (format "backup ~a" name)
    (lambda ()
      (define existing
        (for/hash ([(r s) (in-hash (vault-refmap vault-root ns))]) (values r s)))
      (define (group-here? group)
        (for/or ([r (in-hash-keys existing)])
          (string-prefix? r (string-append ns group "/"))))
      (define specs '())
      (when (group-here? "/heads")
        (set! specs (cons (string-append "+" ns "/heads/*:"
                                         ns "/heads/*")
                          specs)))
      (when (group-here? "/tags")
        (set! specs (cons (string-append "+" ns "/tags/*:"
                                         ns "/tags/*")
                          specs)))
      (when (group-here? "/pinned")
        (set! specs (cons (string-append ns "/pinned/*:"
                                         ns "/pinned/*")
                          specs)))
      (when (group-here? "/superseded")
        (set! specs (cons (string-append ns "/superseded/*:"
                                         ns "/superseded/*")
                          specs)))
      (define res
        (vault-git vault-root
                   (append (list "push" "--progress" "--" remote-url)
                           (reverse specs))
                   #:op 'vault-backup-push #:kind 'fetch
                   #:operation "push namespace backup"
                   #:cancel cancel #:on-progress on-progress))
      (unless (zero? (run-result-exit res))
        (raise-pm-error 'fetch 'vault-backup-push "backup push failed"
                        #:fields (list (cons "name" name)
                                       (cons "detail" (string-join
                                                        (run-result-stderr-lines res)
                                                        "\n")))))
      (backup-push-result name #t #f (reverse specs)))))

;; path-string string string -> (listof backup-status-entry?)
(define (vault-backup-status vault-root name remote-url)
  (define ns (vault-namespace name))
  (check-git-url remote-url)
  (ensure-vault vault-root)
  (define local (vault-refmap vault-root ns))
  (define res
    (vault-git vault-root `("ls-remote" "--" ,remote-url
                            ,(string-append ns "/*"))
               #:op 'vault-backup-status #:kind 'fetch
               #:operation "list backup refs"))
  (vault-git! vault-root 'vault-backup-status '("ls-remote") res 'fetch
              "ls-remote")
  (define remote
    (for/hash ([line (in-list (run-result-stdout-lines res))]
               #:when (regexp-match? #rx"\trefs/vault/" line)
               #:unless (string-suffix? line "^{}"))
      (define m (regexp-match #rx"^([0-9a-f]+)\t(.+)$" line))
      (values (caddr m) (cadr m))))
  (define names
    (sort (remove-duplicates (append (hash-keys local) (hash-keys remote)))
          string<?))
  (for/list ([r (in-list names)])
    (define l (hash-ref local r #f))
    (define b (hash-ref remote r #f))
    (backup-status-entry name r l b
                         (cond [(equal? l b) 'in-sync]
                               [(not l) 'backup-only]
                               [(not b) 'local-only]
                               [else 'diverged]))))

;; path-string string string -> restore-result, explicit refspecs
(define (vault-restore vault-root name backup-url
                       #:cancel [cancel #f]
                       #:on-progress [on-progress #f]
                       #:holder [holder #f])
  (define ns (vault-namespace name))
  (check-git-url backup-url)
  (vault-assert-child-free vault-root)
  (ensure-vault vault-root)
  (call-with-vault-lock vault-root (or holder "interactive")
                        (format "restore ~a" name)
    (lambda ()
      (define before (vault-refmap vault-root ns))
      (with-handlers ([exn:fail:pm?
                       (lambda (e)
                         (vault-add-rollback vault-root ns before)
                         (raise e))])
        (define specs
          (list (string-append "+" ns "/heads/*:" ns "/heads/*")
                (string-append "+" ns "/tags/*:" ns "/tags/*")
                (string-append ns "/pinned/*:" ns "/pinned/*")
                (string-append ns "/superseded/*:" ns "/superseded/*")))
        (define warns
          (vault-fetch-with-retry vault-root backup-url ns '() cancel
                                  on-progress before
                                  #:refspecs specs))
        (define-values (sups warns2 gone)
          (vault-refresh-tail vault-root backup-url ns before))
        (define after (vault-refmap vault-root ns))
        (define restored
          (sort (for/list ([r (in-hash-keys after)]
                           #:unless (hash-has-key? before r))
                  r)
                string<?))
        (restore-result name #t #f restored)))))

;; path-string path-string -> (listof vault-drift?), inventory vs refs
(define (vault-status vault-root manifest-path)
  (ensure-vault vault-root)
  (define entries (manifest-read manifest-path))
  (define names (vault-list vault-root))
  (define missing
    (for/list ([e (in-list entries)]
               #:unless (member (manifest-entry-name e) names))
      (vault-drift 'missing-namespace
                   (format "~a has inventory but no refs"
                           (manifest-entry-name e)))))
  (define unlisted
    (for/list ([n (in-list names)]
               #:unless (manifest-get entries n))
      (vault-drift 'unlisted-namespace
                   (format "~a has refs but no inventory" n))))
  (append missing unlisted))


(module+ test
  (require rackunit
           racket/file
           racket/list
           racket/port
           racket/system
           "../core/errors.rkt"
           "../core/git-url.rkt"
           "../core/cancel.rkt"
         "manifest.rkt")

  ;; file:// fixtures need the test-only URL allowance (production
  ;; rejects them; cli/ never references this parameter).
  (parameterize ([current-allow-file-urls #t])

  (define git-exe (or (find-executable-path "git")
                      (error 'vault-test "git missing")))
  (define test-root (make-temporary-directory "pm-vault~a"))

  ;; Extra env for fixture git commands: identity plus isolation.
  (define (fixture-env)
    `(("GIT_AUTHOR_NAME" . "t")
      ("GIT_AUTHOR_EMAIL" . "t@t")
      ("GIT_COMMITTER_NAME" . "t")
      ("GIT_COMMITTER_EMAIL" . "t@t")
      ("GIT_CONFIG_NOSYSTEM" . "1")
      ("GIT_TERMINAL_PROMPT" . "0")))

  ;; path (listof string) -> void, fixture git must succeed
  (define (fixture-git dir . args)
    (define res
      (run-command git-exe args
                   #:cwd (path->string dir)
                   #:kind 'fetch #:operation "test-fixture"
                   #:env (fixture-env)))
    (unless (zero? (run-result-exit res))
      (error 'vault-fixture "git failed: ~a" args))
    (void))

  ;; string -> path, upstream repo with main, feat branch, v1.0 tag
  (define (make-upstream name)
    (define dir (build-path test-root name))
    (make-directory dir)
    (fixture-git dir "init" "-b" "main" ".")
    (call-with-output-file (build-path dir "f")
      (lambda (out) (displayln "one" out)))
    (fixture-git dir "add" "--" "f")
    (fixture-git dir "commit" "-qm" "first")
    (fixture-git dir "tag" "v1.0")
    (fixture-git dir "branch" "feat")
    (fixture-git dir "checkout" "-q" "feat")
    (call-with-output-file (build-path dir "g")
      (lambda (out) (displayln "two" out)))
    (fixture-git dir "add" "--" "g")
    (fixture-git dir "commit" "-qm" "second")
    (fixture-git dir "checkout" "-q" "main")
    dir)

  ;; path -> string, file:// URL of a fixture repo
  (define (file-url dir)
    (string-append "file://" (path->string dir)))

  ;; string -> string, HEAD sha of a fixture work repo
  (define (fixture-head dir)
    (define res
      (run-command git-exe '("rev-parse" "HEAD")
                   #:cwd (path->string dir)
                   #:kind 'fetch #:operation "test-fixture"
                   #:env (fixture-env)))
    (car (run-result-stdout-lines res)))

  ;; path-string string string -> vault-add-result, fresh vault each call
  (define (fresh-add vname uname #:pin [pin #f])
    (define vault (build-path test-root (string-append "v-" vname)))
    (make-directory vault)
    (vault-init (build-path vault "vault.git"))
    (vault-add (build-path vault "vault.git") vname
               (file-url (build-path test-root uname)) #:pin pin))

  ;; Names derive, never passed in; git agrees they are valid refs.
  (check-equal? (vault-namespace "demo") "refs/vault/demo")
  (for ([bad (in-list '("" "Bad!" "../escape" "a/b" "-lead"))])
    (check-exn exn:fail:pm?
               (lambda () (vault-namespace bad))))
  (define fmt-res
    (run-command git-exe '("check-ref-format" "--print"
                           "refs/vault/demo/heads/main")
                 #:cwd (path->string test-root)
                 #:kind 'fetch #:operation "test-fixture"
                 #:env (fixture-env)))
  (check-equal? (run-result-exit fmt-res) 0)

  ;; URL change is kind 'config pointing at D-013.
  (check-exn exn:fail:pm?
             (lambda ()
               (check-url-unchanged "demo" "file:///a" "file:///b")))
  (check-equal? (check-url-unchanged "demo" "file:///a" "file:///a")
                (void))

  ;; Init writes the config and no remote.* ever.
  (define init-dir (build-path test-root "init-vault"))
  (make-directory init-dir)
  (vault-init (build-path init-dir "vault.git"))
  (check-equal? (vault-list (build-path init-dir "vault.git")) '())
  (define cfg-res
    (run-command git-exe `("--git-dir"
                           ,(path->string (build-path init-dir "vault.git"))
                           "config" "gc.auto")
                 #:cwd (path->string test-root)
                 #:kind 'fetch #:operation "test-fixture"
                 #:env (fixture-env)))
  (check-equal? (run-result-stdout-lines cfg-res) '("0"))

  ;; Two fixtures both tagged v1.0 do not collide.
  (define up-a (make-upstream "up-a"))
  (define up-b (make-upstream "up-b"))
  (define add-a (fresh-add "demo-a" "up-a"))
  (define add-b (fresh-add "demo-b" "up-b"))
  (check-equal? (vault-add-result-namespace add-a) "refs/vault/demo-a")
  (check-equal? (vault-add-result-pin-source add-a) 'remote-head)
  (check-equal? (vault-add-result-pin add-a) (fixture-head up-a))
  (check-true (> (length (vault-add-result-refs-created add-a)) 3))
  (check-equal? (vault-add-result-gone-upstream add-a) '())
  (check-equal? (vault-add-result-superseded add-a) '())
  (define both-vault (build-path test-root "v-both"))
  (make-directory both-vault)
  (vault-init (build-path both-vault "vault.git"))
  (vault-add (build-path both-vault "vault.git") "demo-a" (file-url up-a))
  (vault-add (build-path both-vault "vault.git") "demo-b" (file-url up-b))
  (check-equal? (vault-list (build-path both-vault "vault.git"))
                '("demo-a" "demo-b"))

  ;; Given pin echoes with source 'given; size grows monotonically.
  (define head-a (fixture-head up-a))
  (check-equal? (vault-add-result-pin add-a) head-a)
  (check-true (>= (vault-size-report-bytes
                   (vault-add-result-size-after add-a))
                  (vault-size-report-bytes
                   (vault-add-result-size-before add-a))))
  (define pinned-add (fresh-add "demo-p" "up-a" #:pin head-a))
  (check-equal? (vault-add-result-pin-source pinned-add) 'given)

  ;; Unreachable pin fails kind 'fetch; refs untouched.
  (define bad-vault (build-path test-root "v-bad"))
  (make-directory bad-vault)
  (vault-init (build-path bad-vault "vault.git"))
  (vault-add (build-path bad-vault "vault.git") "demo" (file-url up-a))
  (define before-refs
    (run-command git-exe `("--git-dir" ,(path->string
                                         (build-path bad-vault "vault.git"))
                           "for-each-ref" "refs/vault/demo")
                 #:cwd (path->string test-root)
                 #:kind 'fetch #:operation "test-fixture"
                 #:env (fixture-env)))
  (check-pred fetch-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (vault-add (build-path bad-vault "vault.git") "demo"
                           (file-url up-a)
                           #:pin (make-string 40 #\0))
                'no-error))
  (define after-refs
    (run-command git-exe `("--git-dir" ,(path->string
                                         (build-path bad-vault "vault.git"))
                           "for-each-ref" "refs/vault/demo")
                 #:cwd (path->string test-root)
                 #:kind 'fetch #:operation "test-fixture"
                 #:env (fixture-env)))
  (check-equal? (run-result-stdout-lines after-refs)
                (run-result-stdout-lines before-refs))

  ;; Empty remote is kind 'fetch.
  (define empty-dir (build-path test-root "up-empty"))
  (make-directory empty-dir)
  (fixture-git empty-dir "init" "--bare" ".")
  (define empty-vault (build-path test-root "v-empty"))
  (make-directory empty-vault)
  (vault-init (build-path empty-vault "vault.git"))
  (check-pred fetch-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (vault-add (build-path empty-vault "vault.git") "demo"
                           (file-url empty-dir))
                'no-error))

  ;; Non-fast-forward keeps the old tip under superseded/, with warning.
  ;; Two moves in the same second give two distinct rescue refs.
  (define ff-dir (build-path test-root "up-ff"))
  (make-directory ff-dir)
  (fixture-git ff-dir "init" "-b" "main" ".")
  (call-with-output-file (build-path ff-dir "f")
    (lambda (out) (displayln "one" out)))
  (fixture-git ff-dir "add" "--" "f")
  (fixture-git ff-dir "commit" "-qm" "first")
  (define ff-vault (build-path test-root "v-ff"))
  (make-directory ff-vault)
  (vault-init (build-path ff-vault "vault.git"))
  (define ff1 (vault-add (build-path ff-vault "vault.git") "demo"
                         (file-url ff-dir)))
  (check-equal? (vault-add-result-superseded ff1) '())
  (define tip1 (vault-add-result-pin ff1))
  (call-with-output-file (build-path ff-dir "f")
    (lambda (out) (displayln "two" out)) #:exists 'truncate)
  (fixture-git ff-dir "commit" "-qam" "second")
  (define ff1b (vault-add (build-path ff-vault "vault.git") "demo"
                          (file-url ff-dir)))
  (check-equal? (vault-add-result-superseded ff1b) '())
  (define tip1b (vault-add-result-pin ff1b))
  (fixture-git ff-dir "update-ref" "refs/heads/main" tip1)
  (call-with-output-file (build-path ff-dir "f")
    (lambda (out) (displayln "three" out)) #:exists 'truncate)
  (fixture-git ff-dir "commit" "-qam" "third")
  (define ff2 (vault-add (build-path ff-vault "vault.git") "demo"
                         (file-url ff-dir)))
  (check-equal? (length (vault-add-result-superseded ff2)) 1)
  (check-true (> (length (vault-add-result-warnings ff2)) 0))
  (check-false (member tip1b (list (vault-add-result-pin ff2))))
  ;; The new tip survives the rescue; only the old tip moves.
  (define ff2-main
    (car (run-result-stdout-lines
          (run-command git-exe
                       `("--git-dir" ,(path->string
                                       (build-path ff-vault "vault.git"))
                         "show-ref" "refs/vault/demo/heads/main")
                       #:cwd (path->string test-root)
                       #:kind 'fetch #:operation "test-fixture"
                       #:env (fixture-env)))))
  (check-true (string-prefix? ff2-main (vault-add-result-pin ff2)))
  ;; A second rewrite in the same second rescues under its own old sha.
  (define tip2 (vault-add-result-pin ff2))
  (fixture-git ff-dir "update-ref" "refs/heads/main" tip1b)
  (call-with-output-file (build-path ff-dir "f")
    (lambda (out) (displayln "four" out)) #:exists 'truncate)
  (fixture-git ff-dir "commit" "-qam" "fourth")
  (define ff3 (vault-add (build-path ff-vault "vault.git") "demo"
                         (file-url ff-dir)))
  (check-equal? (length (vault-add-result-superseded ff3)) 1)
  (check-false (equal? (car (vault-add-result-superseded ff3))
                       (car (vault-add-result-superseded ff2))))
  (check-false (member tip2 (list (vault-add-result-pin ff3))))

  ;; D/F conflict: upstream replaces branch a with a/b; the re-add
  ;; rescues the stale ref under superseded/ and retries to success.
  (define df-dir (build-path test-root "up-df"))
  (make-directory df-dir)
  (fixture-git df-dir "init" "-b" "main" ".")
  (call-with-output-file (build-path df-dir "f")
    (lambda (out) (displayln "one" out)))
  (fixture-git df-dir "add" "--" "f")
  (fixture-git df-dir "commit" "-qm" "first")
  (fixture-git df-dir "branch" "a")
  (define df-vault (build-path test-root "v-df"))
  (make-directory df-vault)
  (vault-init (build-path df-vault "vault.git"))
  (vault-add (build-path df-vault "vault.git") "demo" (file-url df-dir))
  (fixture-git df-dir "branch" "-D" "a")
  (fixture-git df-dir "branch" "a/b" "main")
  (define df2 (vault-add (build-path df-vault "vault.git") "demo"
                         (file-url df-dir)))
  (check-true (> (length (vault-add-result-warnings df2)) 0))
  (define df-refs
    (run-command git-exe
                 `("--git-dir" ,(path->string
                                 (build-path df-vault "vault.git"))
                   "for-each-ref" "--format=%(refname)" "refs/vault/demo")
                 #:cwd (path->string test-root)
                 #:kind 'fetch #:operation "test-fixture"
                 #:env (fixture-env)))
  (check-true (if (member "refs/vault/demo/heads/a/b"
                         (run-result-stdout-lines df-refs))
                  #t #f))
  (check-true (if (ormap (lambda (r)
                           (regexp-match? #rx"superseded/.*/heads/a$" r))
                         (run-result-stdout-lines df-refs))
                  #t #f))

  ;; on-progress fires with parsed fields on a real fetch.
  (define seen-progress (box '()))
  (define prog-vault (build-path test-root "v-prog"))
  (make-directory prog-vault)
  (vault-init (build-path prog-vault "vault.git"))
  (vault-add (build-path prog-vault "vault.git") "demo" (file-url up-a)
             #:on-progress (lambda (p)
                             (set-box! seen-progress
                                       (cons p (unbox seen-progress)))))
  (check-true (> (length (unbox seen-progress)) 0))
  (check-true (andmap fetch-progress? (unbox seen-progress)))

  ;; fsck-allow plumbs through; a held child.lock refuses writers.
  (define fsck-vault (build-path test-root "v-fsck"))
  (make-directory fsck-vault)
  (vault-init (build-path fsck-vault "vault.git"))
  (vault-add (build-path fsck-vault "vault.git") "demo" (file-url up-a)
             #:fsck-allow '("badDate"))
  ;; Rendezvous is FIFO opens (events), never sleeps.
  (define flock-exe (find-executable-path "flock"))
  (define mkfifo-exe (find-executable-path "mkfifo"))
  (define sh-exe (find-executable-path "sh"))
  (define up-fifo (build-path fsck-vault "up.fifo"))
  (define block-fifo (build-path fsck-vault "block.fifo"))
  (for ([f (in-list (list up-fifo block-fifo))])
    (let ((maker (process* (path->string mkfifo-exe) (path->string f))))
      ((list-ref maker 4) 'wait)))
  (define holder
    (process* (path->string flock-exe)
              (path->string (build-path fsck-vault "child.lock"))
              (path->string sh-exe) "-c"
              (format "echo up > ~a; read x < ~a"
                      (path->string up-fifo) (path->string block-fifo))))
  ;; The up line arrives only after flock holds child.lock.
  (define up-in (open-input-file up-fifo))
  (check-equal? (read-line up-in) "up")
  (close-input-port up-in)
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (vault-add (build-path fsck-vault "vault.git") "demo2"
                           (file-url up-b))
                'no-error))
  ;; Release through the block fifo; the wait proves the exit.
  (define block-out (open-output-file block-fifo #:exists 'update))
  (displayln "go" block-out)
  (flush-output block-out)
  (close-output-port block-out)
  ((list-ref holder 4) 'wait)
  (check-equal? (vault-add-result-pin
                 (vault-add (build-path fsck-vault "vault.git") "demo2"
                            (file-url up-b)))
                (fixture-head up-b))

  ;; Gone upstream is reported; our ref stays.
  (fixture-git up-a "branch" "-D" "feat")
  (define gone-add (vault-add (build-path both-vault "vault.git") "demo-a"
                              (file-url up-a)))
  (check-equal? (vault-add-result-gone-upstream gone-add) '("heads/feat"))

  ;; Pre-triggered cancel aborts kind 'cancelled.
  (define-values (cancel-evt trigger-cancel!) (make-cancel-source))
  (trigger-cancel!)
  (check-pred cancelled-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (vault-add (build-path both-vault "vault.git") "demo-c"
                           (file-url up-b) #:cancel cancel-evt)
                'no-error))

  ;; fetch-namespace: fast-forward updates without superseding.
  (define fn-dir (build-path test-root "up-fn"))
  (make-directory fn-dir)
  (fixture-git fn-dir "init" "-b" "main" ".")
  (call-with-output-file (build-path fn-dir "f")
    (lambda (out) (displayln "one" out)))
  (fixture-git fn-dir "add" "--" "f")
  (fixture-git fn-dir "commit" "-qm" "first")
  (define fn-vault (build-path test-root "v-fn"))
  (make-directory fn-vault)
  (vault-init (build-path fn-vault "vault.git"))
  (vault-add (build-path fn-vault "vault.git") "demo" (file-url fn-dir))
  (call-with-output-file (build-path fn-dir "f")
    (lambda (out) (displayln "two" out)) #:exists 'truncate)
  (fixture-git fn-dir "commit" "-qam" "second")
  (define fn1 (vault-fetch-namespace (build-path fn-vault "vault.git")
                                     "demo" (file-url fn-dir)))
  (check-equal? (vault-fetch-result-superseded fn1) '())
  (check-equal? (vault-fetch-result-gone-upstream fn1) '())

  ;; fetch-namespace: non-fast-forward rescues with a warning.
  (define fn-f1 (car (let ((r (run-command
                               git-exe '("rev-parse" "HEAD~1")
                               #:cwd (path->string fn-dir)
                               #:kind 'fetch #:operation "test-fixture"
                               #:env (fixture-env))))
                       (run-result-stdout-lines r))))
  (fixture-git fn-dir "update-ref" "refs/heads/main" fn-f1)
  (call-with-output-file (build-path fn-dir "f")
    (lambda (out) (displayln "three" out)) #:exists 'truncate)
  (fixture-git fn-dir "commit" "-qam" "third")
  (define fn2 (vault-fetch-namespace (build-path fn-vault "vault.git")
                                     "demo" (file-url fn-dir)))
  (check-equal? (length (vault-fetch-result-superseded fn2)) 1)

  ;; verify passes on a good vault; gc keeps pins alive.
  (check-true (void? (vault-verify (build-path fn-vault "vault.git"))))
  (check-true (void? (vault-verify (build-path fn-vault "vault.git")
                                   #:full #t)))
  (define fn-pin (vault-add-result-pin
                  (vault-add (build-path fn-vault "vault.git") "demo2"
                             (file-url fn-dir))))
  (vault-gc (build-path fn-vault "vault.git"))
  (define (vault-has? vault ref)
    (zero? (run-result-exit
            (run-command git-exe
                         (list "--git-dir" (path->string vault)
                               "show-ref" "--verify" "--quiet" ref)
                         #:cwd (path->string test-root)
                         #:kind 'fetch #:operation "test-fixture"
                         #:env (fixture-env)))))
  (check-true (vault-has? (build-path fn-vault "vault.git")
                          (string-append "refs/vault/demo2/pinned/" fn-pin)))

  ;; pin survives amend plus aggressive prune.
  (fixture-git fn-dir "commit" "-qam" "amended" "--amend")
  (vault-fetch-namespace (build-path fn-vault "vault.git") "demo"
                         (file-url fn-dir))
  (run-command git-exe
               (list "--git-dir"
                     (path->string (build-path fn-vault "vault.git"))
                     "gc" "--prune=now" "--quiet")
               #:cwd (path->string test-root)
               #:kind 'fetch #:operation "test-fixture"
               #:env (fixture-env))
  (check-true (vault-has? (build-path fn-vault "vault.git")
                          (string-append "refs/vault/demo2/pinned/" fn-pin)))

  ;; export: faithful file list, vault untouched, staging rules.
  (define ex-lines
    (run-command git-exe
                 (list "--git-dir"
                       (path->string (build-path fn-vault "vault.git"))
                       "for-each-ref" "refs/vault/demo")
                 #:cwd (path->string test-root)
                 #:kind 'fetch #:operation "test-fixture"
                 #:env (fixture-env)))
  (define ex-stage (build-path test-root "stage-ex"))
  (make-directory ex-stage)
  (vault-export-commit (build-path fn-vault "vault.git") "demo" fn-pin
                       ex-stage)
  (check-equal? (sort (map path->string (directory-list ex-stage))
                      string<?)
                '("f"))
  (check-false (directory-exists? (build-path ex-stage ".git")))
  (define ex-lines-after
    (run-command git-exe
                 (list "--git-dir"
                       (path->string (build-path fn-vault "vault.git"))
                       "for-each-ref" "refs/vault/demo")
                 #:cwd (path->string test-root)
                 #:kind 'fetch #:operation "test-fixture"
                 #:env (fixture-env)))
  (check-equal? (run-result-stdout-lines ex-lines-after)
                (run-result-stdout-lines ex-lines))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (vault-export-commit (build-path fn-vault "vault.git")
                                     "demo" fn-pin
                                     (build-path test-root "no-such-dir"))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (vault-export-commit (build-path fn-vault "vault.git")
                                     "demo" fn-pin ex-stage)
                'no-error))
  (define bad-stage (build-path test-root "stage-bad"))
  (make-directory bad-stage)
  (check-pred verify-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (vault-export-commit (build-path fn-vault "vault.git")
                                     "demo" (make-string 40 #\0)
                                     bad-stage)
                'no-error))

  ;; outer-repo safety: the suite runs with cwd inside the outer repo;
  ;; no vault file may appear beside the code.
  (check-false (file-exists? (build-path (current-directory) "child.lock")))
  (check-false (directory-exists? (build-path (current-directory)
                                              "vault.git")))

  ;; Backup round trip to a local bare remote, then status.
  (define bk-dir (build-path test-root "up-bk"))
  (make-directory bk-dir)
  (fixture-git bk-dir "init" "-b" "main" ".")
  (call-with-output-file (build-path bk-dir "f")
    (lambda (out) (displayln "one" out)))
  (fixture-git bk-dir "add" "--" "f")
  (fixture-git bk-dir "commit" "-qm" "first")
  (fixture-git bk-dir "tag" "v1.0")
  (define bk-vault (build-path test-root "v-bk"))
  (make-directory bk-vault)
  (vault-init (build-path bk-vault "vault.git"))
  (vault-add (build-path bk-vault "vault.git") "demo" (file-url bk-dir))
  (define bk-remote (build-path test-root "backup.git"))
  (fixture-git test-root "init" "--bare" "backup.git")
  (define pushed
    (vault-backup-push (build-path bk-vault "vault.git") "demo"
                       (file-url bk-remote)))
  (check-true (backup-push-result-ok? pushed))
  (check-true (> (length (backup-push-result-pushed-refs pushed)) 1))
  ;; Re-push is idempotent and still ok.
  (check-true (backup-push-result-ok?
               (vault-backup-push (build-path bk-vault "vault.git") "demo"
                                  (file-url bk-remote))))
  (define st1 (vault-backup-status (build-path bk-vault "vault.git") "demo"
                                   (file-url bk-remote)))
  (define (st1-state suffix)
    (define hit
      (for/or ([e (in-list st1)])
        (and (string-suffix? (backup-status-entry-ref e) suffix) e)))
    (and hit (backup-status-entry-state hit)))
  ;; Pushed refs are in sync; remote-head is never pushed by design.
  (check-equal? (st1-state "heads/main") 'in-sync)
  (check-equal? (st1-state "tags/v1.0") 'in-sync)
  (check-equal? (length st1) 4)
  (check-eq? (st1-state "remote-head") 'local-only)
  ;; New local commit shows as local-only and diverged-free.
  (call-with-output-file (build-path bk-dir "f")
    (lambda (out) (displayln "two" out)) #:exists 'truncate)
  (fixture-git bk-dir "commit" "-qam" "second")
  (vault-fetch-namespace (build-path bk-vault "vault.git") "demo"
                         (file-url bk-dir))
  (define st2 (vault-backup-status (build-path bk-vault "vault.git") "demo"
                                   (file-url bk-remote)))
  (check-true (ormap (lambda (e) (eq? (backup-status-entry-state e) 'local-only))
                     st2))

  ;; Restore rebuilds a fresh vault from the backup.
  (define re-vault (build-path test-root "v-restore"))
  (make-directory re-vault)
  (vault-init (build-path re-vault "vault.git"))
  (define restored
    (vault-restore (build-path re-vault "vault.git") "demo"
                   (file-url bk-remote)))
  (check-true (restore-result-ok? restored))
  (check-true (> (length (restore-result-refs-restored restored)) 2))

  ;; Status drift: inventory without refs, and refs without inventory.
  (define drift-vault (build-path test-root "v-drift"))
  (make-directory drift-vault)
  (vault-init (build-path drift-vault "vault.git"))
  (vault-add (build-path drift-vault "vault.git") "demo" (file-url bk-dir))
  (define drift-manifest (build-path test-root "drift.rktd"))
  (manifest-write drift-manifest
                  (list (manifest-entry "demo" (file-url bk-dir)
                                        "refs/vault/demo" 1 2 '() #f)
                        (manifest-entry "ghost" (file-url bk-dir)
                                        "refs/vault/ghost" 3 #f '() #f)))
  (define drifts (vault-status (build-path drift-vault "vault.git")
                               drift-manifest))
  (check-equal? (length drifts) 1)
  (check-eq? (vault-drift-kind (car drifts)) 'missing-namespace)

  ;; Large blobs refuse without the explicit flag.
  (define big-dir (build-path test-root "up-big"))
  (make-directory big-dir)
  (fixture-git big-dir "init" "-b" "main" ".")
  (define head-exe (find-executable-path "head"))
  (define big-out
    (open-output-file (build-path big-dir "big") #:exists 'truncate))
  (define head-proc
    (process* (path->string head-exe) "-c" "100000001" "/dev/zero"))
  (copy-port (list-ref head-proc 0) big-out)
  (close-output-port big-out)
  (close-input-port (list-ref head-proc 0))
  ((list-ref head-proc 4) 'wait)
  (fixture-git big-dir "add" "--" "big")
  (fixture-git big-dir "commit" "-qm" "big")
  (define big-vault (build-path test-root "v-big"))
  (make-directory big-vault)
  (vault-init (build-path big-vault "vault.git"))
  (vault-add (build-path big-vault "vault.git") "demo" (file-url big-dir))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (vault-backup-push (build-path big-vault "vault.git") "demo"
                                   (file-url bk-remote))
                'no-error))

  (delete-directory/files test-root)))
