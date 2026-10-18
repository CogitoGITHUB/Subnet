#lang racket/base
;; build-plan.rkt -- the public promise for build execution: the
;; environment a step runs in, one step, the plural recipe runner, and
;; the host-tool preflight. It must not add logic of its own; the jobs
;; live in build-env.rkt, build-executor.rkt and build-systems/*.rkt.
;; The contracts stay HERE, on the entry point, so blame lands on the
;; caller of execute-build-step and not on the module that happens to
;; hold the definition. dev-link.rkt is the one caller.

(require racket/contract/base
         "../spec/spec.rkt"
         "build-env.rkt"
         "build-executor.rkt")

(provide
 (contract-out
  ;; keyword dirs -> env extras for spawn-and-wait (D-025, SPEC-NEUTRAL 5)
  [build-env (-> #:prefix path-string?
                 #:source path-string?
                 #:work path-string?
                 (listof (cons/c string? string?)))]
  ;; build-step plus dirs -> void, one vocabulary word or kind 'config
  [execute-build-step
   (->* (build-step?
         #:source path-string?
         #:work path-string?
         #:prefix path-string?)
        (#:env (listof (cons/c string? string?)))
        void?)]
  ;; (listof build-step) plus dirs -> void, in order, stops at failure.
  ;; #:tools is the ecosystem host-tool list (E-25): checked BEFORE the
  ;; first step, so a missing compiler fails before anything is built.
  [execute-build-steps
   (->* ((listof build-step?)
         #:source path-string?
         #:work path-string?
         #:prefix path-string?)
        (#:env (listof (cons/c string? string?))
         #:tools (listof string?))
        void?)]
  ;; (listof string) -> void, or kind 'config naming the missing tool
  [require-host-tools (-> (listof string?) void?)]))
