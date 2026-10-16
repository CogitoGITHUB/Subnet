#lang racket/base
;; plan.rkt -- the entry point and the public promise for planning: the
;; action structs, plan and package-plan, plus the plain procedures the
;; rest of the repo calls. It must not add logic of its own.

(require racket/contract/base
         "spec.rkt"
         "plan-actions.rkt"
         "plan-conflicts.rkt"
         "plan-derive.rkt"
         "plan-hash.rkt"
         "plan-lower.rkt")

(provide
 (struct-out fetch-action)
 (struct-out extract-action)
 (struct-out run-step-action)
 (struct-out install-file-action)
 (struct-out write-file-action)
 (struct-out symlink-action)
 (struct-out remove-path-action)
 (struct-out export-action)
 (struct-out check-action)
 (struct-out mark-incomplete-action)
 (struct-out clear-incomplete-action)
 (struct-out set-current-action)
 (struct-out plan)
 (struct-out package-plan)
 (contract-out
  ;; any -> boolean, one of the eight action kinds below
  [action? (-> any/c boolean?)]
  ;; plan -> string, one line per action in order, stable for goldens
  [plan->text (-> plan? string?)]
  ;; (listof action) -> plan
  [list->plan (-> (listof action?) plan?)]
  ;; package-plan -> string, stable multi-line rendering for goldens
  [package-plan->text (-> package-plan? string?)]
  ;; spec (listof cons) (listof string) -> package-plan, one package
  [derive-package-plan
   (-> spec? (listof (cons/c symbol? boolean?)) (listof string?)
       package-plan?)]
  ;; (listof spec) (listof cons) (listof cons) -> (listof package-plan),
  ;; deps-first order; cycles and missing providers raise kind 'resolve
  ;; through resolve.rkt, flag problems kind 'config through flags.rkt
  [derive-plans
   (-> (listof spec?) (listof (cons/c symbol? boolean?))
       (listof (cons/c symbol? boolean?)) (listof package-plan?))]
  ;; package-plan -> string, store path below <state>/store (D-023):
  ;; name/slot/version-hash12; two slots plan to two dirs
  [package-plan-store-dir (-> package-plan? string?)]
  ;; package-plan string string string string -> (listof action?), one
  ;; package lowered in stage order (E-06)
  ;; spec -> destinations, plan-time conflict surface (G-01)
  [spec-install-dests (-> spec? (listof string?))]
  ;; (listof spec) -> void, kind 'activate naming both on collision
  [check-spec-conflicts (-> (listof spec?) void?)]
  [lower-package-plan
   (-> package-plan? string? string? string? string? (listof action?))]
  ;; (listof package-plan) x4 string lists -> (listof action?), deps-first
  ;; order kept, shared identities emitted once (E-06)
  [lower-plans
   (-> (listof package-plan?) (listof string?) (listof string?)
       (listof string?) (listof string?) (listof action?))]))

;; ---------------------------------------------------------------------------
;; This file used to do four jobs at once: the action structs, the
;; hashing, the derivation and the lowering, all under one contract
;; block. Each job now lives in one file of its own and the split runs
;; strictly downward, so nothing can cycle:
;;
;;   plan-actions.rkt   the structs, plan, package-plan, action?
;;   plan-hash.rkt      the sha1 hex, the canonical text, the two paths
;;   plan-derive.rkt    spec plus resolved flags -> package-plan
;;   plan-lower.rkt     package-plan -> actions, and the stable text
;;   plan-conflicts.rkt which destinations two specs both claim
;;
;; The contract block below is the public promise and has not changed:
;; twelve files require this module and it is all they use. The contracts
;; stay HERE, on the entry point, so blame lands on the caller of
;; plan->text and not on the module that happens to hold the definition.

;; ---------------------------------------------------------------------------
;; A test that only exercises the promise above stays here. This one
;; builds its plans through derive-package-plan and asks for their store
;; dirs: it needs plan-hash.rkt (store-dir) and plan-derive.rkt (the
;; plans), and plan-hash.rkt cannot require plan-derive.rkt without
;; cycling, because derivation hashes what it produces.

(module+ test
  (require rackunit
           "spec.rkt"
           "version.rkt")

  ;; E-04 fixture: pkg-alpha on pkg-beta, synthetic and local (T-10).
  (define alpha-spec
    (spec 'pkg-alpha (string->version "2.0") "Alpha"
          (source "https://example.org/alpha.git"
                  "9edb3f66fd807b096b48283debdcddccfea34bad")
          (list (dep 'pkg-beta (string->version "1.0")))
          '()
          (list (build-step 'copy '("a" "b")))
          (install-spec 'prefix '((bin "alpha" "bin/alpha")
                                  (check "bin/alpha" "--version")))
          'mit "https://example.org/alpha" #f '() '()
          'default
          (list (flag-spec 'gui #t "GUI" '() '()))))

  ;; Two slots of one package plan to two store dirs.
  (define alpha-alt
    (struct-copy spec alpha-spec [slot 'lts]))
  (check-false (equal? (package-plan-store-dir
                        (derive-package-plan alpha-spec '((gui . #t))
                                             '("pkg-beta 1.0")))
                       (package-plan-store-dir
                        (derive-package-plan alpha-alt '((gui . #t))
                                             '("pkg-beta 1.0"))))))
