#lang racket/base
;; plan-conflicts.rkt -- the destination paths each spec claims at plan
;; time, and the refusal when two claim one. It must not lower, derive
;; or render anything.
;;
;; The suite moved to
;; package-manager/tests/spec/plan-conflicts-test.rkt (phase A step 14,
;; 2026-10-17, where it also drives the refusal through the plan path
;; the plan command runs; D-068).

(require
 "../errors/error-type.rkt"
 "spec.rkt")

(provide
 ;; spec -> (listof string), destination rels this spec claims
 spec-install-dests
 ;; (listof spec) -> void, kind 'activate naming both on collision
 check-spec-conflicts)

;; ---------------------------------------------------------------------------
;; Plan-time conflicts (G-01, DEFAULT: fail). Two packages claiming one
;; destination fail AT PLAN TIME with kind 'activate naming both, never
;; half-install and complain later. Dests mirror lower-one-install so
;; the two cannot drift: bin/lib/include/share/man/libexec take the
;; second rel when two are given, copy-tree takes its DST, symlink
;; takes its LINK; mode and check own nothing.

;; spec -> (listof string), destination rels this spec claims
(define (spec-install-dests s)
  (define forms (install-spec-forms (spec-install s)))
  (for/list ([f (in-list forms)]
             #:when (and (pair? f) (memq (car f) '(bin lib include share man
                                                     libexec copy-tree symlink))))
    (define kind (car f))
    (define args (filter string? (cdr f)))
    (cond [(memq kind '(bin lib include share man libexec))
           (if (and (pair? args) (pair? (cdr args)))
               (cadr args)
               (car args))]
          [(eq? kind 'copy-tree) (cadr args)]
          [(eq? kind 'symlink) (cadr args)]
          [else (car args)])))

;; (listof spec) -> void, or kind 'activate naming both packages
(define (check-spec-conflicts specs)
  (define seen (make-hash))
  (for ([s (in-list specs)])
    (define name (symbol->string (spec-name s)))
    (for ([d (in-list (spec-install-dests s))])
      (define prior (hash-ref seen d #f))
      (when prior
        (raise-pm-error 'activate 'check-spec-conflicts
                        (format "path conflict: ~a and ~a both claim ~a"
                                prior name d)
                        #:fields `(("path" . ,d)
                                   ("owned-by" . ,prior)
                                   ("claimed-by" . ,name))))
      (hash-set! seen d name))))
