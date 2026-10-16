#lang racket/base
;; profile-gc.rkt -- reclaiming space (G-05, DEFAULT: last 5, holds and
;; the live link are absolute): keep the newest KEEP generations, the
;; live one the profile link points at, and any generation owning a
;; currently held package; delete the rest and say exactly what went
;; and why. Generations without pruning are a disk bomb, but a pruner
;; that eats the live tree is worse.

(require racket/file
         racket/list
         racket/path
         "../narration/narration.rkt"
         "generation.rkt"
         "profile-holds.rkt")

(provide
 ;; path-string #:keep -> (kept deleted); contracts stay on the facade
 profile-gc)

;; path-string #:keep -> (kept deleted), G-05 prunes generations
(define (profile-gc profile-root #:keep [keep 5])
  (with-op 'gc (if (path? profile-root) (path->string profile-root)
                   (format "~a" profile-root))
           (format "generations past ~a go, the live and held stay" keep)
           (lambda ()
             (define gens (map first (profile-generations profile-root)))
             (define live
               (with-handlers ([(lambda (e) #t) (lambda (e) #f)])
                 (path->string (resolve-path
                                (build-path profile-root "profile")))))
             (define held-names (map first (read-holds profile-root)))
             (step 'gc "survey"
                   "every generation is measured against keep, live and held")
             (define (keeper? g i)
               (or (< i keep)
                   (and live (equal? (path->string g) live))
                   (for/or ([n (in-list (generation-owner-names g))])
                     (member n held-names))))
             (define-values (kept doomed)
               (for/fold ([k '()] [d '()])
                         ([g (in-list (reverse gens))]
                          [i (in-naturals)])
                 (if (keeper? g i)
                     (values (cons g k) d)
                     (values k (cons g d)))))
             (for ([g (in-list doomed)])
               (step 'gc (path->string (file-name-from-path g))
                     "past keep, neither live nor holding a held package")
               (delete-directory/files g))
             (for ([g (in-list kept)])
               (skip 'gc (path->string (file-name-from-path g))
                     "within keep, or live, or holding a held package"))
             (list kept doomed))))
