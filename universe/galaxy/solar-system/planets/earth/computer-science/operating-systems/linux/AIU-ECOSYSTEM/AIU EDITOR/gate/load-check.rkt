#lang racket/base
;; One job: the load check — every module of the package is loaded, and a
;; module that does not load is named. Registered in
;; plan/package-tree.org; lands with TODO item 6.
;;
;; The check LOADS the modules and never runs their commands: a module
;; that does not load is a module that cannot be used, and loading it says
;; so. Each module is loaded in a namespace of its own, so two modules
;; that happen to share a name do not hide each other.
;;
;; The check found a real fault the first time it ran: the cancellation
;; door had a struct with no mutator, so the module never loaded. A gate
;; that only reads the text of a file cannot see that; a gate that loads
;; the file can.
;;
;; The check runs from the gate directory, so the package is reached by a
;; relative path: a module path that holds a space cannot be opened by
;; an absolute one on this Racket.

(require racket/file
         racket/list
         racket/path
         racket/runtime-path)

;; project-dir is the directory above the gate: the project itself.
(define-runtime-path project-dir "..")

;; package-src is the directory the areas live in, one level below the
;; project directory.
(define package-src
  (build-path project-dir "editor" "src"))

;; walk answers every file under a directory, in a fixed order, so the
;; check reads the same files in the same order every time.
(define (walk dir)
  (append*
   (for/list ([name (in-list (sort (directory-list dir) path<?))])
     (define full (build-path dir name))
     (if (directory-exists? full) (walk full) (list full)))))

;; modules answers the Racket files of the package, the ones the check
;; loads.
(define modules
  (filter (lambda (f) (regexp-match? #px"\\.rkt$" (path->string f)))
          (walk package-src)))

;; load-one loads one module in a namespace of its own, and answers
;; nothing when the module loads and the reason when it does not.
(define (load-one f)
  (with-handlers ([exn:fail?
                   (lambda (why)
                     (format "the module ~a does not load: ~a"
                             (path->string f)
                             (exn-message why)))])
    (define resolved (make-resolved-module-path f))
    (parameterize ([current-namespace (make-base-namespace)])
      (dynamic-require resolved #f))
    #f))

;; main loads every module and answers what is wrong, one line per
;; fault. It exits non-zero when a module does not load.
(define (main)
  (define bad (filter values (for/list ([f (in-list modules)]) (load-one f))))
  (if (null? bad)
      (begin
        (printf "OK load-check — ~a modules loaded cleanly\n" (length modules))
        (exit 0))
      (begin
        (for-each (lambda (fault) (printf "LOAD — ~a\n" fault)) bad)
        (printf "LOAD — ~a of ~a modules do not load\n" (length bad) (length modules))
        (exit 1))))

;; The check, for the dispatcher above.
(module+ main
  (main))
