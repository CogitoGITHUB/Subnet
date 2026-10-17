#lang racket/base
;; drain-test.rkt -- the moved-out test submodule of src/process/drain.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/list
            racket/string
            "../../src/process/progress.rkt"
         "../../src/process/drain.rkt")

(module+ test
  (require rackunit)

  ;; Direct unit pins for redact-credentials (the redaction check). The
  ;; end-to-end proof that a secret never reaches a tail or a log file
  ;; stays in run.rkt, because it needs a real child.
  (check-equal? (redact-credentials "https://user:s3cret@example.com/x")
                "https://<redacted>@example.com/x")
  (check-equal? (redact-credentials "token=abc123")
                "token=<redacted>")
  (check-equal? (redact-credentials "https://example.com/x")
                "https://example.com/x")
  (check-equal? (redact-credentials "https://<redacted>@example.com/x")
                "https://<redacted>@example.com/x"))

