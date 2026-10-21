#lang racket/base
;; One job: the one place HOME / XDG is read.
;; Registered in plan/package-tree.org. No other file in the package calls
;; getenv or spells a home path: one seam, one place to change, one answer when
;; HOME is missing. gate/env.nu mirrors this seam for Nushell.
(require "../errors/err.rkt"
         "../errors/raise.rkt")

;; provide is the five answers of the seam: config, state, cache, runtime, home.
(provide home-dir
         xdg-config-home
         xdg-state-home
         xdg-cache-home
         xdg-runtime-dir)

;; home-dir answers $HOME. A machine with no HOME is refused by name rather than
;; given a guessed fallback: every later path would be a lie.
(define (home-dir)
  (define h (getenv "HOME"))
  (if (and (string? h) (not (blank-string? h)))
      h
      (raise-error "HOME is not set"
                   "machine/directories home-dir"
                   "the environment"
                   "no HOME means no honest place for config, state or locks"
                   #:rule 'directories/home-required)))

;; xdg answers one XDG variable, or the default under HOME. The defaults are the
;; XDG spec's, so a machine that sets only HOME still gets one answer.
(define (xdg variable default)
  (define v (getenv variable))
  (if (and (string? v) (not (blank-string? v))) v default))

;; xdg-config-home answers where config lives: $XDG_CONFIG_HOME, else
;; $HOME/.config.
(define (xdg-config-home)
  (xdg "XDG_CONFIG_HOME" (build-path (home-dir) ".config")))

;; xdg-state-home answers where state lives: $XDG_STATE_HOME, else
;; $HOME/.local/state. A lock and a log are state, never config.
(define (xdg-state-home)
  (xdg "XDG_STATE_HOME" (build-path (home-dir) ".local" "state")))

;; xdg-cache-home answers where caches live: $XDG_CACHE_HOME, else $HOME/.cache.
(define (xdg-cache-home)
  (xdg "XDG_CACHE_HOME" (build-path (home-dir) ".cache")))

;; xdg-runtime-dir answers where sockets may live: $XDG_RUNTIME_DIR, else
;; $TMPDIR, else /tmp. Both fallbacks are named here, not hidden in a caller.
(define (xdg-runtime-dir)
  (define v (getenv "XDG_RUNTIME_DIR"))
  (define t (getenv "TMPDIR"))
  (cond
    [(and (string? v) (not (blank-string? v))) v]
    [(and (string? t) (not (blank-string? t))) t]
    [else "/tmp"]))
