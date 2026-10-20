#lang racket/base
;; One job: the last good bake — the path of the last build that was
;; good, and the answer whether a candidate may take its place. Registered
;; in plan/package-tree.org; lands with TODO item 8.
;;
;; A bake that goes wrong must never ship: the last good stays the last
;; good, and the bad one is kept beside it so the owner can look at it.
;; The rule is one line: the last good build is kept.

(require racket/file
         racket/string
         "../machine/directories.rkt")

;; last-good-file is where the path of the last good build is kept.
(define last-good-file
  (build-path (state-dir) "last-good"))

;; last-good answers the path of the last good build, or nothing when
;; there has never been one.
(define (last-good)
  (if (file-exists? last-good-file)
      (let ([text (string-trim (file->string last-good-file))])
        (if (string=? text "") #f text))
      #f))

;; keep-last-good records a build as the last good one. It is called
;; only when the build has already been found good.
(define (keep-last-good path)
  (ensure-dir (state-dir))
  (call-with-output-file last-good-file
    (lambda (port) (display path port))
    #:exists 'truncate)
  path)

;; good-answers says whether the build answered as it should: the check
;; is the caller's, because only the caller knows what good means for
;; the thing it baked.
(define (good-answers? answers expected)
  (and (pair? answers) (equal? (car answers) expected)))

;; The last good build, for the bake beside it.
(provide last-good-file
         last-good
         keep-last-good
         good-answers?)
