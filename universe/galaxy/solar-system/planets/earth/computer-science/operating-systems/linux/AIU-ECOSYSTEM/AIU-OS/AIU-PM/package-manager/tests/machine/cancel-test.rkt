#lang racket/base
;; cancel-test.rkt -- the moved-out test submodule of src/machine/cancel.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
         "../../src/machine/cancel.rkt")

(module+ test
  (require rackunit)

  ;; Delivery is event-driven: each worker blocks on its own source and
  ;; reports through one shared channel; the test takes exactly arrivals.
  (define arrivals (make-channel))
  (define (spawn-worker tag)
    (define-values (cancel-evt trigger!) (make-cancel-source))
    (thread (lambda ()
              (sync cancel-evt)
              (channel-put arrivals tag)))
    trigger!)
  (define trigger-a! (spawn-worker 'a))
  (define trigger-b! (spawn-worker 'b))

  ;; Firing B delivers B while A stays pending (independent sources).
  (trigger-b!)
  (check-equal? (channel-get arrivals) 'b)

  ;; Firing A afterwards delivers A; double posts change nothing observable.
  (trigger-a!)
  (trigger-a!)
  (check-equal? (channel-get arrivals) 'a))

