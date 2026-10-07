#lang racket/base
;; cancel.rkt -- semaphore cancel sources shared by CLI, jobs and tests.
;; Firing is posting to a semaphore: extra posts are harmless, delivery is
;; synchronous, and nothing here involves a clock (D-015).

(require racket/contract/base)

(provide
 (contract-out
  ;; -> cancel-evt trigger!, one fresh semaphore source per call
  [make-cancel-source (-> (values evt? (-> void?)))]))

;; ---------------------------------------------------------------------------
;; Sources

;; -> (values evt trigger!), fresh source; trigger posts, repeat posts harmless
(define (make-cancel-source)
  (define s (make-semaphore))
  (values s (lambda () (semaphore-post s))))

;; ---------------------------------------------------------------------------
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
