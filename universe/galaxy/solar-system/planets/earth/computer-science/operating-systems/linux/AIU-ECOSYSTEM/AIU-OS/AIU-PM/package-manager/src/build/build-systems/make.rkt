#lang racket/base
;; build-systems/make.rkt -- the make and make-info words: build the
;; command, resolve the dir, hand back exe, argv and cwd. It spawns
;; nothing; build-executor.rkt runs it.

(require "../build-env.rkt")

(provide
 ;; (listof any) path path -> (values string (listof string) path)
 make-command
 ;; doc make through the same binary
 make-info-command)

;; (listof any) path path -> (values string (listof string) path), make
(define (make-command args work source)
  (define dir (resolve-dir 'make (as-string (arg-val args '#:dir ".")
                                            ".")
                           work source))
  (define file (arg-val args '#:file #f))
  (define targets (as-strings (arg-val args '#:targets '())))
  (define vars (vars->flags (arg-val args '#:vars '())))
  (define jobs (arg-val args '#:jobs #f))
  (values "make"
          (append (if (string? file) (list "-f" file) '())
                  targets
                  vars
                  (if (or (integer? jobs) (string? jobs))
                      (list (string-append "-j" (format "~a" jobs)))
                      '()))
          dir))

;; (listof any) path path -> (values string (listof string) path), doc make
(define (make-info-command args work source)
  (define dir (resolve-dir 'make-info (as-string (arg-val args '#:dir ".")
                                                 ".")
                           work source))
  (define targets (as-strings (arg-val args '#:targets '())))
  (values "make" targets dir))
