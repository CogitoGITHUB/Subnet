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
