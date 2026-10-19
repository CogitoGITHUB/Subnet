#lang racket/base
;; events-dir.rkt -- WHERE the run feed lives: <state>/events for one
;; scope, and the feed file one run writes inside it. This is filesystem
;; location, so it belongs beside the ONE seam that reads HOME or XDG
;; (machine/directories.rkt, D-029) rather than in narration/, which
;; sits BELOW machine and may not reach up for it: the one-way law
;; (plan/ARCHITECTURE.org, gate/one-way-dependency-lint.nu, D-044).
;;
;; The direction that replaced the illegal reach is the same inversion
;; build/build-cache.rkt uses for its tree hash: the caller that may see
;; both areas answers the where, and narration/ takes the answer as an
;; argument. One place names the path, so the CLI run and the MCP feed
;; reader can never drift onto different roots.

(require racket/contract/base
         "./directories.rkt")

(provide
 (contract-out
  ;; symbol -> path, <state>/events for SCOPE, exactly as the roots say
  [events-dir (-> symbol? path?)]
  ;; path path-string -> path, the feed file for RUN-ID under DIR
  [events-file (-> path? path-string? path?)]))

;; ---------------------------------------------------------------------------
;; The one place the path is written down

;; symbol -> path
(define (events-dir scope)
  (build-path (roots-data (scope-roots scope)) "aiu-pm" "events"))

;; path path-string -> path
(define (events-file dir run-id)
  (build-path dir (string-append run-id ".jsonl")))
