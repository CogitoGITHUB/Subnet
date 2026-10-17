#lang racket/base
;; activate.rkt -- the public promise for profile generations: the
;; atomic profile swap and everything around it (ENGINE.org
;; backends/activate.rkt, SPEC-NEUTRAL section 4, E-13). Generations
;; are profile-NNN/ dirs of absolute symlinks; activate validates
;; everything first, builds the next generation, then flips the
;; profile link with store.rkt's atomic swap: a conflict fails closed
;; with kind 'activate (exit 9) before anything changes. E-15's
;; rollback and remove are here too; hold pins slots in
;; profile/holds.rktd.
;;
;; This facade must not add logic of its own; the jobs live in
;; generation.rkt, profile-flip.rkt, profile-gc.rkt and
;; profile-holds.rkt. The contracts stay HERE, on the entry point, so
;; blame lands on the caller of profile-activate and not on the module
;; that happens to hold the definition.
;;
;; The suite is promise-level, end to end across all four
;; modules; it lives in package-manager/tests/install/activate-test.rkt
;; since TODO.org phase A step 14 (the tests moved out on 2026-10-17).

(require racket/contract/base
         "generation.rkt"
         "profile-flip.rkt"
         "profile-gc.rkt"
         "profile-holds.rkt")

(provide
 (contract-out
  ;; (listof entry) path-string -> path, next generation, profile flips
  [profile-activate (->* ((listof (list/c string? path-string?
                                          (listof string?)))
                          path-string?)
                         (#:interface string?
                          #:specs (listof string?)
                          #:lock (or/c string? #f))
                         path?)]
  ;; path-string -> (listof (gen provenance)), oldest first; provenance
  ;; is #f for generations predating it, else (run-id interface specs lock)
  [profile-generations (-> path-string?
                           (listof (list/c path? (or/c #f (list/c (or/c string? #f)
                                                                  string?
                                                                  (listof string?)
                                                                  (or/c string? #f))))))]
  ;; generation dir -> provenance or #f, never raises
  [generation-provenance (-> path-string?
                             (or/c #f (list/c (or/c string? #f)
                                              string?
                                              (listof string?)
                                              (or/c string? #f))))]
  ;; path-string exact-integer -> path, repoint profile at generation N
  [profile-rollback (-> path-string? exact-integer? path?)]
  ;; path-string string (listof entry) -> path, generation minus one
  [profile-remove (-> path-string? string?
                      (listof (list/c string? path-string?
                                      (listof string?)))
                      path?)]
  ;; path-string string string -> void, pin a slot against updates
  [profile-hold (-> path-string? string? string? void?)]
  ;; path-string string string -> void, release a slot pin
  [profile-unhold (-> path-string? string? string? void?)]
  ;; path-string string string -> boolean, is the slot pinned
  [profile-held? (-> path-string? string? string? boolean?)]
  ;; path-string -> path, where the profile link points today
  [current-generation (-> path-string? path?)]
  ;; path-string -> (listof (name slot)), absent reads as none held
  [read-holds (-> path-string? (listof (list/c string? string?)))]
  ;; path-string -> (kept deleted), G-05 prunes generations
  [profile-gc (->* (path-string?)
                   (#:keep exact-positive-integer?)
                   (list/c (listof path?) (listof path?)))]))

;; ---------------------------------------------------------------------------
