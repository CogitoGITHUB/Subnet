#lang racket/base
;; print-console-test.rkt -- the moved-out test submodule of src/narration/print-console.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            "../../src/errors/error-type.rkt"
            "../../src/narration/event-text.rkt"
         "../../src/narration/print-console.rkt")

(module+ test
  (require rackunit
           racket/string
           "../../src/errors/error-type.rkt")

  ;; The errors.rkt boundary is real here: this submodule imports it,
  ;; so kind typos fail with a contract error (not silently).
  (check-exn exn:fail:contract?
             (lambda () (raise-pm-error 'fetsh 'w 'm)))

  ;; User errors print the clean message to the given port.
  (define err-out (open-output-string))
  (display-pm-error
   (with-handlers ([exn:fail:pm? (lambda (e) e)])
     (raise-pm-error 'fetch 'fetch-source "download failed"
                     #:fields '(("url" . "https://x.test/a.tgz"))
                     #:hint "check the URL"))
   #:port err-out)
  (check-equal? (get-output-string err-out)
                (string-append
                 (string-join '("fetch-source: download failed;"
                                "  url: https://x.test/a.tgz"
                                "  hint: check the URL")
                              "\n")
                 "\n"))

  ;; Cancelled prints plainly with NO bug banner (D-015): it is a user
  ;; action, not a defect. display-pm-error already prints cleanly.
  (define cancel-out (open-output-string))
  (display-pm-error
   (with-handlers ([exn:fail:pm? (lambda (e) e)])
     (raise-pm-error 'cancelled 'spawn-and-wait "cancelled"
                     #:fields '(("operation" . "fetch demo"))))
   #:port cancel-out)
  (check-regexp-match #rx"fetch demo" (get-output-string cancel-out))
  (check-false (regexp-match? #rx"bug" (get-output-string cancel-out)))

  ;; Internal errors carry the bug banner.
  (define bug-out (open-output-string))
  (display-internal-error (exn:fail "broken invariant"
                                    (current-continuation-marks))
                          #:port bug-out)
  (check-true
   (regexp-match? #rx"this is a bug" (get-output-string bug-out)))
  (check-true
   (regexp-match? #rx"context:" (get-output-string bug-out)))

  ;; Warnings collect in scope and print oldest-first with a count.
  (define warn-out (open-output-string))
  (parameterize ([current-collected-warnings (box '())])
    (warn! "disk almost full")
    (warn! "slow network")
    (display-warning-summary #:port warn-out))
  (check-equal? (get-output-string warn-out)
                "warning: disk almost full\nwarning: slow network\n2 warnings\n")

  ;; display-result: one line per item, and NOTHING for an empty list.
  (define res-out (open-output-string))
  (display-result '("first" "second") #:port res-out)
  (check-equal? (get-output-string res-out) "first\nsecond\n")
  (define empty-res (open-output-string))
  (display-result '() #:port empty-res)
  (check-equal? (get-output-string empty-res) "")

  ;; Empty collection prints just the zero count.
  (define empty-out (open-output-string))
  (parameterize ([current-collected-warnings (box '())])
    (display-warning-summary #:port empty-out))
  (check-equal? (get-output-string empty-out) "0 warnings\n"))

