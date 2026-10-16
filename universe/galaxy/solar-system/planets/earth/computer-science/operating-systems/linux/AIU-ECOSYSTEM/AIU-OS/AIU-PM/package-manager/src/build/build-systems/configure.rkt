#lang racket/base
;; build-systems/configure.rkt -- the configure word: the step dir's own
;; ./configure script with its flags. It builds the command only;
;; build-executor.rkt spawns it.

(require racket/path
         "../build-env.rkt")

(provide
 ;; (listof any) path path -> (values string (listof string) path)
 configure-command)

;; (listof any) path path -> (values string (listof string) path)
(define (configure-command args work source)
  (define dir (resolve-dir 'configure (as-string (arg-val args '#:dir ".")
                                                 ".")
                           work source))
  (define flags (as-strings (arg-val args '#:args '())))
  (values (path->string (build-path dir "configure")) flags dir))
