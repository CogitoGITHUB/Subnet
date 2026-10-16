#lang racket/base
;; kill-tree.rkt -- kill one child's WHOLE process group with pkill and
;; reap the killer's own ports. It must not spawn the child, read its
;; output, or say what the result means.

(require racket/system)

(provide
 ;; path -> (-> exact-int void), tree killer closing its own ports
 make-killer)

;; Racket process groups are unavailable under proot
;; (subprocess-group-enabled -> #f, probed 2026-10-06), so children launch
;; via setsid (own process group) and die here through pkill -g on cancel.
;;
;; path -> (-> exact-int void)
(define (make-killer pkill-exe)
  (lambda (pgid)
    (define killer
      (process* (path->string pkill-exe) "-KILL" "-g"
                (number->string pgid)))
    ((list-ref killer 4) 'wait)
    (close-input-port (list-ref killer 0))
    (close-output-port (list-ref killer 1))
    (close-input-port (list-ref killer 3))))
