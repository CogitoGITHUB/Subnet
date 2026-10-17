#lang racket/base
;; cancel-wait-test.rkt -- the moved-out test submodule of src/process/cancel-wait.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   "../../src/errors/error-type.rkt"
            "../../src/narration/narration.rkt"
            "../../src/process/status-fifo.rkt"
         "../../src/process/cancel-wait.rkt")

(module+ test
  (require rackunit
           "../../src/machine/cancel.rkt")

  ;; wait-command decision matrix, no children: line wins, EOF without a
  ;; line is died, cancel kills through the given thunk exactly once.
  (define matrix-line (make-channel))
  (void (thread (lambda () (channel-put matrix-line "EXIT:0"))))
  (check-equal? (wait-command matrix-line never-evt
                              (lambda () (error "must not kill")))
                "EXIT:0")
  (define matrix-cancelled (make-channel))
  (define killed-box (box #f))
  (define-values (matrix-cancel matrix-fire!) (make-cancel-source))
  (matrix-fire!)
  (check-equal? (wait-command matrix-cancelled matrix-cancel
                              (lambda () (set-box! killed-box #t)))
                'cancelled)
  (check-true (unbox killed-box))
  ;; A line that arrived with cancel still counts as completion.
  (define matrix-both (make-channel))
  (void (thread (lambda () (channel-put matrix-both "EXIT:5"))))
  (check-equal? (wait-command matrix-both matrix-cancel
                              (lambda () (error "must not kill")))
                "EXIT:5"))

