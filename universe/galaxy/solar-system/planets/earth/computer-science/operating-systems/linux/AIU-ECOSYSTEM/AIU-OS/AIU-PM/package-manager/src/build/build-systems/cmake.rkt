#lang racket/base
;; build-systems/cmake.rkt -- the three cmake words: configure a source
;; tree into a build dir, build targets in it, install from it. Each
;; builds a command and hands back exe, argv and cwd; build-executor.rkt
;; spawns it.

(require racket/path
         "../build-env.rkt")

(provide
 ;; (listof any) path path string -> (values string (listof string) path)
 cmake-configure-command
 ;; (listof any) path path -> (values string (listof string) path)
 cmake-build-command
 ;; (listof any) path path -> (values string (listof string) path)
 cmake-install-command)

;; (listof any) path path string -> (values string (listof string) path)
(define (cmake-configure-command args work source prefix)
  (define src-rel (as-string (arg-val args '#:srcdir ".") "."))
  (check-confined src-rel 'cmake-configure)
  (define src
    (let ([s (build-path source src-rel)])
      (if (directory-exists? s)
          s
          (build-path work src-rel))))
  (define bld-rel (as-string (arg-val args '#:builddir "build") "build"))
  (define bld (resolve-builddir bld-rel work 'cmake-configure))
  (define defs (pairs->flags (arg-val args '#:defines '()) "-D"))
  (values "cmake"
          (append (list "-S" (path->string src)
                        "-B" (path->string bld))
                  defs
                  (list (string-append "-DCMAKE_INSTALL_PREFIX="
                                       prefix)))
          work))

;; (listof any) path path -> (values string (listof string) path), build
(define (cmake-build-command args work source)
  (define bld-rel (as-string (arg-val args '#:builddir "build") "build"))
  (define bld (resolve-builddir bld-rel work 'cmake-build))
  (define jobs (arg-val args '#:jobs #f))
  (define targets (as-strings (arg-val args '#:targets '())))
  (define job-flags
    (if (or (integer? jobs) (string? jobs))
        (list "-j" (format "~a" jobs))
        '()))
  (define target-flags
    (apply append (map (lambda (t) (list "--target" t)) targets)))
  (values "cmake"
          (append (list "--build" (path->string bld))
                  job-flags
                  target-flags)
          work))

;; (listof any) path path -> (values string (listof string) path), install
(define (cmake-install-command args work source)
  (define bld-rel (as-string (arg-val args '#:builddir "build") "build"))
  (check-confined bld-rel 'cmake-install)
  (define bld (build-path work bld-rel))
  (values "cmake"
          (list "--install" (path->string bld))
          work))
