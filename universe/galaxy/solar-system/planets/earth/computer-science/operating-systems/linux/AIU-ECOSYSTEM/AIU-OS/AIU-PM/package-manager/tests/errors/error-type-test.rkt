#lang racket/base
;; error-type-test.rkt -- the moved-out test submodule of src/errors/error-type.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            racket/string
         "../../src/errors/error-type.rkt")

(module+ test
  (require rackunit
           syntax/parse)

  ;; Bare message carries no ';' (item 3).
  (check-equal?
   (with-handlers ([exn:fail:pm? exn-message])
     (raise-pm-error 'fetch 'fetch-source "download failed"))
   "fetch-source: download failed")

  ;; Full shape, golden sample for docs/ERRORS.org.
  (check-equal?
   (with-handlers ([exn:fail:pm? exn-message])
     (raise-pm-error 'fetch 'fetch-source "download failed"
                     #:fields '(("url" . "https://x.test/a.tgz"))
                     #:hint "check the URL"
                     #:cause (exn:fail "net down"
                                       (current-continuation-marks))))
   (string-join '("fetch-source: download failed;"
                  "  url: https://x.test/a.tgz"
                  "  cause: net down"
                  "  hint: check the URL")
                "\n"))

  ;; Kind typos fail at the boundary (pm-kind/c as a value rejects).
  ;; NOTE: module+ test sees local bindings uncontracted, so the check
  ;; below exercises the contract value directly; ui.rkt's tests exercise
  ;; the real cross-module boundary.
  (check-exn exn:fail:contract?
             (lambda ()
               ((contract pm-kind/c (lambda (x) x) 'test 'test) 'fetsh)))

  ;; Exit codes per docs/ERRORS.org: config is 78 (EX_CONFIG), internal
;; is 70 (EX_SOFTWARE).
  (define (code-for kind)
    (pm-error-exit-code
     (exn:fail:pm "m" (current-continuation-marks) kind '() #f #f)))
  (check-equal? (map code-for '(spec resolve fetch verify build install
                                activate config cancelled internal))
                '(3 4 5 6 7 8 9 78 130 70))

  ;; Cancelled carries operation, completed and remaining-state (D-015 sample).
  (check-equal?
   (with-handlers ([exn:fail:pm? exn-message])
     (raise-pm-error 'cancelled 'run-command "cancelled"
                     #:fields '(("operation" . "fetch demo")
                                ("completed" . ("spawned" "tree killed"))
                                ("remaining-state" . ("temp files removed" "no result")))))
   (string-join '("run-command: cancelled;"
                  "  operation: fetch demo"
                  "  completed: (spawned tree killed)"
                  "  remaining-state: (temp files removed no result)")
                "\n"))
  (check-equal? (code-for 'cancelled) 130)
  (check-pred cancelled-error?
              (exn:fail:pm "m" (current-continuation-marks) 'cancelled '() #f #f))

  ;; Predicates sort by kind.
  (define fetch-exn
    (exn:fail:pm "m" (current-continuation-marks) 'fetch '() #f #f))
  (check-true (fetch-error? fetch-exn))
  (check-false (fetch-error? (exn:fail "plain" (current-continuation-marks))))
  (check-false (fetch-error? "not-an-exn"))

  ;; Syntax failures wrap with srcloc fields and the original cause.
  (define in (open-input-string "(42 oops)"))
  (port-count-lines! in)
  (define bad-syntax (read-syntax "spec.rktd" in))
  (define wrapped
    (with-handlers ([exn:fail:syntax? (lambda (e) (syntax-error->pm-error e 'spec))])
      (syntax-parse bad-syntax [({~datum define} _.id) "matched"])))
  (check-pred spec-error? wrapped)
  (check-equal? (exn:fail:pm-kind wrapped) 'spec)
  (check-equal? (exn:fail:pm-fields wrapped) '(("at" . "spec.rktd:1:2")))
  (check-pred exn:fail:syntax? (exn:fail:pm-cause wrapped))

  ;; Leading spaces move the column; columns count from 1.
  (define spaced-in (open-input-string "  (42 oops)"))
  (port-count-lines! spaced-in)
  (define spaced-syntax (read-syntax "spec.rktd" spaced-in))
  (define spaced-wrapped
    (with-handlers ([exn:fail:syntax? (lambda (e) (syntax-error->pm-error e 'spec))])
      (syntax-parse spaced-syntax [({~datum define} _.id) "matched"])))
  (check-equal? (exn:fail:pm-fields spaced-wrapped) '(("at" . "spec.rktd:1:4"))))

