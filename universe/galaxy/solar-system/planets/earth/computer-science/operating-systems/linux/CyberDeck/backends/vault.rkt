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
         "../core/errors.rkt"
         "../core/git-id.rkt"
         "../core/git-url.rkt"
         "../core/spec.rkt"
         "../core/vault-lock.rkt"
         "run.rkt")

(provide
 (struct-out fetch-progress)
 (struct-out vault-add-result)
 (struct-out vault-size-report)
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
  [vault-size (-> path-string? vault-size-report?)]))

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
            (if git-dir
                (list (string-append "--git-dir=" (dir-string vault-root)))
                '())
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
(define (vault-fetch-run vault-root url ns fsck-allow cancel on-progress)
  (vault-git vault-root
             (append (append-map (lambda (id)
                                   (list "-c"
                                         (string-append "fsck." id "=ignore")))
                                 fsck-allow)
                     (list "fetch" "--progress" "--no-tags"
                           "--no-write-fetch-head"
                           "--" url
                           (string-append "+refs/heads/*:" ns "/heads/*")
                           (string-append "+refs/tags/*:" ns "/tags/*")))
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
      (define res (vault-fetch-run vault-root url ns fsck-allow cancel
                                   on-progress))
      (define warns '())
      (define fetch-failed? (not (zero? (run-result-exit res))))
      (define collisions
        (and fetch-failed?
             (vault-df-collisions vault-root ns url before)))
      (cond [(not fetch-failed?) (void)]
            [(null? collisions)
             (vault-git! vault-root 'vault-add '("fetch") res 'fetch
                         "fetch")]
            [else
                   (for ([r (in-list collisions)])
                     (let-values ([(sup warn)
                                   (vault-rescue-ref vault-root ns r
                                                     (hash-ref before r))])
                       (set! warns (cons warn warns))))
                   (let ((retry (vault-fetch-run vault-root url ns
                                                 fsck-allow cancel
                                                 on-progress)))
                     (unless (zero? (run-result-exit retry))
                       (vault-git! vault-root 'vault-add '("fetch") retry
                                   'fetch "fetch"))
                     (set! warns (cons "retried fetch after ref rescue"
                                       warns)))])
      (define pin* (or pin (vault-resolve-head vault-root url)))
      (unless pin
        (vault-set-ref vault-root (string-append ns "/remote-head") pin*))
      (vault-assert-reachable vault-root ns pin* url)
      (vault-set-ref vault-root
                     (string-append ns "/pinned/" pin*) pin*)
      (define-values (sups warns2) (vault-supersede-moves vault-root ns
                                                          before))
      (define gone-upstream
        (let ((advertised (vault-advertised vault-root url))
              (ours (for/list ([r (in-hash-keys
                                   (tips-only (vault-refmap vault-root ns)
                                              ns))])
                      (define m (regexp-match
                                 #rx"refs/vault/[^/]+/(heads|tags)/(.+)$" r))
                      (string-append (cadr m) "/" (caddr m)))))
          (sort (for/list ([o (in-list ours)]
                           #:unless (member o advertised))
                  o)
                string<?)))
      (vault-pack-refs vault-root)
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

;; path-string -> (listof string), namespaces present, sorted
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
(module+ test
  (require rackunit
           racket/file
           racket/list
           racket/system
           "../core/errors.rkt"
           "../core/git-url.rkt"
           "../core/cancel.rkt")

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

  (delete-directory/files test-root)))
