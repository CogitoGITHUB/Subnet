#lang racket/base
;; install.rkt -- the install phase: place a built tree into PREFIX
;; (ENGINE.org backends/install.rkt, E-09).
;;
;; No fork of the placement logic: install-actions! refuses anything
;; that is not a placement action, then runs the list through
;; local-perform! from backends/local.rkt (D-025 keeps it the single
;; placement implementation). Fetch, run steps and the E-11 actions
;; therefore fail with kind 'config before anything runs: the install
;; phase can never fetch or build. PREFIX is explicit; no HOME, no
;; XDG, no environment reads anywhere in this module.

(require racket/contract/base
         "./local-perform.rkt"
         "../errors/error-type.rkt"
         "../spec/plan.rkt")

(provide
 (contract-out
  ;; (listof action) #:prefix -> void, install phase through local
  [install-actions! (-> (listof action?) #:prefix path-string? void?)]))

;; any -> boolean, the four placement actions local-perform! owns
(define (install-action? a)
  (or (install-file-action? a)
      (write-file-action? a)
      (symlink-action? a)
      (remove-path-action? a)))

;; (listof action) #:prefix -> void, non-install refuses first
(define (install-actions! actions #:prefix prefix)
  (for ([a (in-list actions)])
    (unless (install-action? a)
      (raise-pm-error 'config 'install-actions!
                      "not an install action"
                      #:fields `(("value" . ,(format "~s" a))))))
  (local-perform! (list->plan actions) #:prefix prefix #:commit #f))

;; ---------------------------------------------------------------------------
