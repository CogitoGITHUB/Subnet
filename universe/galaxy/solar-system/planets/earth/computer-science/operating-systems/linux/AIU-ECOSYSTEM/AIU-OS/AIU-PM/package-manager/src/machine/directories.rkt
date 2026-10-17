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
         "../errors/error-type.rkt")

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
;;
;; Three ups, not one: src/machine -> src -> package-manager -> the repo
;; root. One up landed on package-manager/src and the nu file below was
;; never found. The restructure then moved scripts/env.nu to gate/env.nu.
(define-runtime-path checkout-dir "../../..")

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
