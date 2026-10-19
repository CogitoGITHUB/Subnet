#lang racket/base
;; plan-derive.rkt -- turns one spec plus its resolved flags into a
;; package-plan, and a whole spec set into plans in deps-first order. It
;; must not lower, render or check spec conflicts.

(require racket/list
         "../errors/error-type.rkt"
         "flags.rkt"
         "resolve.rkt"
         "spec.rkt"
         "./version.rkt"
         "plan-actions.rkt"
         "plan-hash.rkt")

(provide
 ;; spec (listof cons) (listof string) -> package-plan, one package
 derive-package-plan
 ;; (listof spec) (listof cons) (listof cons) -> (listof package-plan)
 derive-plans
 ;; The field guard the action structs in plan-actions.rkt use, named
 ;; here too so a reader looking for plan-field checks finds it in the
 ;; file that reasons about plan fields. Defined one file down.
 check-string-fields)

;; ---------------------------------------------------------------------------
;; Derivation (spec + resolved flags + dep identities -> package-plan)

;; spec (listof cons) (listof string) -> package-plan, one package.
;; The flags must cover exactly the declared names (a resolution from
;; another spec is caller error, kind 'config); dep identities arrive
;; sorted "name version" strings from the caller.
(define (derive-package-plan specification resolved dep-identities)
  (define declared-names (map flag-spec-name (spec-flags specification)))
  (define given-names (map car resolved))
  (unless (and (= (length declared-names) (length given-names))
               (andmap (lambda (n) (memq n declared-names)) given-names))
    (raise-pm-error 'config 'derive-package-plan
                    "flags do not match declared"
                    #:fields `(("spec" . ,(format "~a"
                                                 (spec-name specification))))))
  (define forms (install-spec-forms (spec-install specification)))
  (define check-form
    (let ((found (filter (lambda (form)
                           (and (pair? form) (eq? (car form) 'check)))
                         forms)))
      (if (null? found) #f (car found))))
  (define proto
    (package-plan (spec-name specification)
                  (spec-slot specification)
                  (spec-version specification)
                  (source-commit (spec-source specification))
                  resolved
                  (sort dep-identities string<?)
                  (spec-build specification)
                  (spec-install specification)
                  check-form
                  "pending"))
  (struct-copy package-plan proto
               [input-hash (string-sha1hex
                            (package-plan-canonical proto))]))

;; (listof spec) (listof cons) (listof cons) -> (listof package-plan),
;; deps-first order via resolve.rkt: missing providers and cycles raise
;; kind 'resolve there; flag problems raise kind 'config in flags.rkt.
(define (derive-plans specifications global-config per-package-config)
  (define ordered (resolve specifications specifications))
  (for/list ([s (in-list ordered)])
    (derive-package-plan
     s
     (resolve-flags s global-config per-package-config)
     (for/list ([d (in-list (spec-deps s))])
       (format "~a ~a"
               (dep-name d)
               (version->string (dep-version d)))))))

;; ---------------------------------------------------------------------------
;; One spec becomes one plan, and the hash says whether two derivations
;; of the same spec agree (plan-hash.rkt owns the hash itself).
