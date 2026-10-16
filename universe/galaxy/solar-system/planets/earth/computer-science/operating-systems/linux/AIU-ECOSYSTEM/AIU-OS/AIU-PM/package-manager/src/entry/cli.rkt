#lang racket/base
;; cli.rkt -- the public promise of the pm command line: the command
;; structs, the parser, the renderers and the helpers, re-provided
;; with their contracts. The jobs live in dispatch.rkt (commands,
;; parsing, rendering, run-command-json, run-cli) and documents.rkt
;; (the result documents and the help text); this facade must not add
;; logic of its own, and the module+ main below is the executable door.

(require racket/contract/base
         json
         "dispatch.rkt"
         "documents.rkt")

(provide
 (struct-out command-check)
 (struct-out command-help)
 (struct-out command-plan)
 (struct-out command-lock)
 (struct-out command-fetch)
 (struct-out command-apply)
 (struct-out command-update)
 (struct-out command-activate)
 (struct-out command-rollback)
 (struct-out command-remove)
 (struct-out command-hold)
 (struct-out command-why)
 (struct-out command-owner)
 (struct-out command-verify)
 (struct-out command-status)
 (struct-out command-held)
 (struct-out command-outdated)
 (contract-out
  ;; any -> boolean, a parsed command value
  [command? (-> any/c boolean?)]
  ;; (vectorof string) -> command, bad usage raises kind 'config
  [parse-args (-> (vectorof string?) command?)]
  ;; command -> string, stable sexp shape for goldens
  [command->sexp (-> command? string?)]
  ;; command -> string, fixed key order until E-26 hardens the schema
  [command->json (-> command? string?)]
  ;; path-string -> exit code, validates every .rktd, 0 or 3
  [run-check (-> path-string? exact-nonnegative-integer?)]
  ;; command -> string, the exact --format json document: the envelope
  ;; from command->json plus that command's result keys. Raises kind
  ;; 'config for a command that is not executable yet (E-18 debt).
  [run-command-json (-> command? string?)]
  ;; jsexpr -> string, the value as JSON text (write-json alone
  ;; prints and returns void)
  [json-text (-> jsexpr? string?)]
  ;; -> void, prints usage to stdout
  [display-help (-> void?)]))

;; ---------------------------------------------------------------------------
(module+ main
  ;; The run, its handlers and the exit code live in dispatch.rkt's
  ;; run-cli; this file keeps the promise and the door.
  (exit (run-cli (current-command-line-arguments))))
