#lang racket/base
;; plan-conflicts.rkt -- the destination paths each spec claims at plan
;; time, and the refusal when two claim one. It must not lower, derive
;; or render anything.

(require
 "errors.rkt"
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

;; ---------------------------------------------------------------------------
;; Two specs claiming one path is the whole subject here, so these tests
;; build their specs from the spec constructor and never lower anything.

(module+ test
  (require rackunit
           "errors.rkt"
           "spec.rkt"
           "version.rkt")

  ;; E-04 fixture: pkg-alpha claims bin/alpha and owns one check form
  ;; (T-10), the same declaration plan-derive.rkt turns into a plan.
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

  ;; G-01: dests mirror lowering (second rel wins); a shared
  ;; destination refuses with kind 'activate naming both packages.
  (check-equal? (spec-install-dests alpha-spec) '("bin/alpha"))
  (define clash-a
    (struct-copy spec alpha-spec
                 [name 'pkg-clash-a]
                 [install (install-spec 'prefix '((bin "tool" "bin/tool")))]))
  (define clash-b
    (struct-copy spec alpha-spec
                 [name 'pkg-clash-b]
                 [install (install-spec 'prefix '((bin "tool" "bin/tool")))]))
  (check-true (with-handlers ([exn:fail:pm? (lambda (e) #f)])
                (check-spec-conflicts (list alpha-spec clash-a))
                #t))
  (define clash-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (check-spec-conflicts
       (list clash-a clash-b
             (struct-copy spec alpha-spec
                          [name 'pkg-clash-c]
                          [install (install-spec 'prefix '((bin "tool")))])))
      'no-error))
  (check-pred activate-error? clash-err)
  (check-regexp-match #rx"pkg-clash-a" (exn-message clash-err))
  (check-regexp-match #rx"pkg-clash-b" (exn-message clash-err))
  (check-regexp-match #rx"bin/tool" (exn-message clash-err)))
