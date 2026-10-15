#lang racket/base
;; scope.rkt -- the scope seam (D-029). The ONE place in non-test Racket
;; code that reads HOME or XDG_* (the other is scripts/env.nu on the Nu
;; side). Every .rkt resolves roots through here; nothing else calls
;; getenv for XDG_* or HOME, and nothing calls find-system-path for them
;; (find-system-path 'exec-file for locating binaries is unrelated: it
;; answers "which program", never "whose directories").
;;
;; v1 ships user scope only. A second scope with its own store, lock,
;; manifest, profile and root-owned roots is deferred with MappingOS;
;; asking for it now raises kind 'config naming the deferral, never
;; silently half-working. Roots carried here are config, cache and data
;; only: store/profile layout is owned by E-07/E-13, not by this seam.

(require racket/contract/base
         racket/runtime-path
         racket/string
         "errors.rkt")

(provide
 (struct-out roots)
 (contract-out
  ;; symbol -> roots, user scope today; anything else is deferred
  [scope-roots (-> symbol? roots?)]
  ;; (listof path-string) -> (listof path), the spec search order
  [spec-search-roots (-> (listof path-string?) (listof path?))]))

;; The checkout dir, resolved from THIS FILE's location rather than the
;; cwd. `raco test core/scope.rkt` sets the cwd to core/, so a path built
;; from (current-directory) named core/scripts/env.nu, which does not
;; exist, and the nu subprocess failed with module_not_found. A path that
;; claims not to depend on the cwd has to be built from something that is
;; not the cwd.
(define-runtime-path checkout-dir "..")

;; ---------------------------------------------------------------------------
;; Roots (D-029: store, profile, state, config, cache come from one scope;
;; this struct carries the three this seam resolves, all as paths)

(struct roots (config cache data)
  #:transparent
  #:guard (lambda (config cache data _n)
            (unless (and (path? config) (path? cache) (path? data))
              (raise-pm-error 'internal 'roots "roots must be paths"
                              #:fields `(("value" . ,(format "~s"
                                                            (list config
                                                                  cache
                                                                  data))))))
            (values config cache data)))
;; config : path?  XDG_CONFIG_HOME or ~/.config
;; cache  : path?  XDG_CACHE_HOME or ~/.cache
;; data   : path?  XDG_DATA_HOME or ~/.local/share (D-005 state home)

;; string string -> path, XDG value verbatim or HOME fallback. Blank
;; counts as unset, like the Nu side (env.nu trims too). The XDG value is
;; the directory itself (XDG spec), never joined with anything; only the
;; HOME fallback appends the leaf name. Every branch yields a path, as
;; the roots guard requires.
(define (xdg-or-home var fallback-dir)
  (define raw (getenv var))
  (define home (getenv "HOME"))
  (cond [(and raw (not (string=? (string-trim raw) "")))
         (string->path (string-trim raw))]
        [(and home (not (string=? (string-trim home) "")))
         (build-path (string-trim home) fallback-dir)]
        [else
         (build-path (find-system-path 'home-dir)
                     fallback-dir)]))

;; symbol -> roots, the single seam (D-029)
(define (scope-roots scope)
  (cond [(eq? scope 'user)
         (roots (xdg-or-home "XDG_CONFIG_HOME" ".config")
                (xdg-or-home "XDG_CACHE_HOME" ".cache")
                (xdg-or-home "XDG_DATA_HOME" ".local/share"))]
        [else
         (raise-pm-error 'config 'scope-roots "system scope deferred"
                         #:fields `(("scope" . ,(format "~a" scope)))
                         #:hint "v1 ships user scope only (D-029)")]))

;; ---------------------------------------------------------------------------
;; Spec discovery (G-06). Channels are gone, so this contract answers
;; "where do .rktd sets live?" in one place. The order is the policy:
;; explicit directories first, in the caller's order, then the config
;; tree, then the local vault side of the data tree. There is no fourth
;; source and especially no network: this function builds local paths
;; only, so discovery can never fetch. Nothing calls it yet -- the CLI
;; still takes an explicit DIR -- and that is recorded here rather than
;; hidden: the wiring waits on the command set coming off "not
;; executable yet".

;; (listof path-string) -> (listof path), duplicates removed, order kept
(define (spec-search-roots explicit)
  (define r (scope-roots 'user))
  (define candidates
    (append (map (lambda (d) (if (path? d) d (string->path d))) explicit)
            (list (build-path (roots-config r) "aiu-pm" "specs")
                  (build-path (roots-data r) "aiu-pm" "specs"))))
  (reverse
   (for/fold ([seen '()])
             ([p (in-list candidates)])
     (if (member p seen) seen (cons p seen)))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/system
           json
           "errors.rkt")

  ;; (listof (cons bytes bytes)) -> environment-variables, controlled env:
  ;; XDG_* from the cases below, HOME always set, PATH passed through so
  ;; the nu binary stays findable in the cross-language test
  (define (test-env pairs)
    (define ev (environment-variables-copy (current-environment-variables)))
    (for ([p (in-list pairs)])
      (environment-variables-set! ev (car p) (cdr p)))
    ev)

  (define ev-full
    (test-env (list (cons #"XDG_CONFIG_HOME" #"/tmp/pm-scope/config")
                    (cons #"XDG_CACHE_HOME" #"/tmp/pm-scope/cache")
                    (cons #"XDG_DATA_HOME" #"/tmp/pm-scope/data")
                    (cons #"HOME" #"/tmp/pm-scope/home"))))

  ;; XDG set: used verbatim.
  (check-equal?
   (parameterize ([current-environment-variables ev-full])
     (map path->string
          (list (roots-config (scope-roots 'user))
                (roots-cache (scope-roots 'user))
                (roots-data (scope-roots 'user)))))
   '("/tmp/pm-scope/config" "/tmp/pm-scope/cache" "/tmp/pm-scope/data"))

  ;; XDG unset: HOME fallbacks. The live environment carries real
  ;; XDG_CONFIG_HOME and XDG_DATA_HOME, so they are explicitly removed
  ;; here (#f unbinds); otherwise the test would measure the room, not
  ;; the fallback.
  (define ev-home-only
    (test-env (list (cons #"XDG_CONFIG_HOME" #f)
                    (cons #"XDG_CACHE_HOME" #f)
                    (cons #"XDG_DATA_HOME" #f)
                    (cons #"HOME" #"/tmp/pm-scope/home"))))
  (check-equal?
   (parameterize ([current-environment-variables ev-home-only])
     (map path->string
          (list (roots-config (scope-roots 'user))
                (roots-cache (scope-roots 'user))
                (roots-data (scope-roots 'user)))))
   '("/tmp/pm-scope/home/.config"
     "/tmp/pm-scope/home/.cache"
     "/tmp/pm-scope/home/.local/share"))

  ;; Blank counts as unset, like the Nu side.
  (define ev-blank
    (test-env (list (cons #"XDG_CACHE_HOME" #"   ")
                    (cons #"HOME" #"/tmp/pm-scope/home"))))
  (check-equal?
   (parameterize ([current-environment-variables ev-blank])
     (path->string (roots-cache (scope-roots 'user))))
   "/tmp/pm-scope/home/.cache")

  ;; Anything but user scope is deferred, kind 'config.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (scope-roots 'system)
                'no-error))

  ;; Both implementations resolve identical roots for the user scope:
  ;; the same controlled env drives Racket above and nu below (nu reads
  ;; its own process env, which carries the parameterized table). nu runs
  ;; behind sh: Racket exports PWD with a trailing slash, which this nu
  ;; refuses, so sh resets the directory first and execs (measured).
  (define sh-bin
    (or (find-executable-path "sh")
        (error 'scope-test "sh not found")))
  (define nu-bin
    (or (find-executable-path "nu")
        (let ((pinned (build-path (find-system-path 'home-dir)
                                  "opt" "nushell" "0.116.1" "nu")))
          (and (file-exists? pinned) pinned))
        (error 'scope-test "nu binary not found")))
  ;; The checkout dir without a trailing slash, so the absolute `use`
  ;; path below never depends on the cwd nu starts in.
  (define here-dirs
    (let ((d (path->string (simplify-path checkout-dir))))
      (if (and (> (string-length d) 1)
               (string-suffix? d "/"))
          (substring d 0 (- (string-length d) 1))
          d)))
  (define nu-json (build-path (find-system-path 'temp-dir)
                              "pm-scope-nu.json"))
  (define nu-log (build-path (find-system-path 'temp-dir)
                              "pm-scope-nu.log"))
  (when (file-exists? nu-json) (delete-file nu-json))
  (define nu-out (open-output-file nu-log #:exists 'truncate/replace))
  (define nu-err (open-output-file (string-append (path->string nu-log)
                                                  ".err")
                                   #:exists 'truncate/replace))
  (define nu-in (open-input-file "/dev/null"))
  (define nu-prog
    (string-append "use " here-dirs
                   "/scripts/env.nu [scope-roots]; scope-roots | to json | save "
                   (path->string nu-json)))
  (define nu-shell
    (string-append "cd /tmp && exec " (path->string nu-bin)
                   " --no-config-file -c '" nu-prog "'"))
  (define nu-r
    (parameterize ([current-environment-variables ev-full])
      (process*/ports nu-out nu-in nu-err
                      (path->string sh-bin)
                      "-c" nu-shell)))
  (close-input-port nu-in)
  ((list-ref nu-r 4) 'wait)
  (define nu-code ((list-ref nu-r 4) 'exit-code))
  (close-output-port nu-out)
  (close-output-port nu-err)
  (check-equal? nu-code 0)
  (define nu-roots
    (call-with-input-file nu-json read-json))
  (delete-file nu-json)
  (delete-file nu-log)
  (delete-file (string-append (path->string nu-log) ".err"))
  (check-equal?
   (parameterize ([current-environment-variables ev-full])
     (map path->string
          (list (roots-config (scope-roots 'user))
                (roots-cache (scope-roots 'user))
                (roots-data (scope-roots 'user)))))
   (list (hash-ref nu-roots 'config)
         (hash-ref nu-roots 'cache)
         (hash-ref nu-roots 'data)))

  ;; G-06: explicit dirs first in order, then config, then data. No
  ;; network source exists anywhere in the answer.
  (check-equal?
   (parameterize ([current-environment-variables ev-full])
     (map path->string (spec-search-roots '("/x/specs" "/y/specs"))))
   '("/x/specs" "/y/specs"
     "/tmp/pm-scope/config/aiu-pm/specs"
     "/tmp/pm-scope/data/aiu-pm/specs"))
  ;; Duplicates collapse, order kept; empty explicit still yields the two.
  (check-equal?
   (parameterize ([current-environment-variables ev-full])
     (map path->string
          (spec-search-roots '("/x/specs" "/x/specs"))))
   '("/x/specs"
     "/tmp/pm-scope/config/aiu-pm/specs"
     "/tmp/pm-scope/data/aiu-pm/specs"))
  (check-equal?
   (parameterize ([current-environment-variables ev-full])
     (map path->string (spec-search-roots '())))
   '("/tmp/pm-scope/config/aiu-pm/specs"
     "/tmp/pm-scope/data/aiu-pm/specs")))
