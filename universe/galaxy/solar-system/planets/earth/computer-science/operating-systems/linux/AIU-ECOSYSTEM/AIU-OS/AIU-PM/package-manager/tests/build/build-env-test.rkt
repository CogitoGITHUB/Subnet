#lang racket/base
;; build-env-test.rkt -- the moved-out test submodule of src/build/build-env.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/file
            racket/list
            racket/path
            racket/string
            "../../src/errors/error-type.rkt"
         "../../src/build/build-env.rkt")

(module+ test
  (require rackunit)

  ;; G-09: the build env carries no ambient network configuration.
  ;; Proxy variables are present but empty, so no proxy (and no proxy
  ;; credentials) reaches a build step. Synthetic dirs only (T-10).
  (define work (make-temporary-directory "pm-buildenv~a"))
  (define benv (build-env #:prefix work #:source work #:work work))
  (for ([v (in-list '("http_proxy" "https_proxy"
                      "HTTP_PROXY" "HTTPS_PROXY"))])
    (check-equal? (cdr (assoc v benv)) ""))
  (delete-directory/files work))

