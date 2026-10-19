#lang racket/base
;; One job: the one place HOME and XDG are read.
;; Registered in plan/package-tree.org; lands with TODO item 1.
;;
;; One scope seam for the environment and the roots: no other file in this
;; program reads an environment variable, so where the program looks is one
;; place to change and one place to look when a path is wrong.

(require racket/file
         racket/path
         "../errors/raise.rkt")

;; home-dir returns the user's home directory, and refuses when HOME is not
;; set, because a program with no home has nowhere to keep anything.
(define (home-dir)
  (define h (getenv "HOME"))
  (if (or (not h) (string=? h ""))
      (error-of 'err-no-home "the editor" "the home directory"
                "HOME is not set" "set HOME to the home directory and run again")
      (path->complete-path h)))

;; xdg-dir returns the XDG directory of the given kind, and falls back to the
;; default place under the home directory when the variable is not set.
(define (xdg-dir kind fallback)
  (define value (getenv (string-append "XDG_" (string-upcase kind) "_HOME")))
  (if (and value (not (string=? value "")))
      (path->complete-path value)
      (build-path (home-dir) fallback)))

;; config-dir returns the editor's configuration directory.
(define (config-dir)
  (build-path (xdg-dir "config" ".config") "aiu-editor"))

;; state-dir returns the editor's state directory: the journal and the locks
;; live here, because they are the things that must survive a crash.
(define (state-dir)
  (build-path (xdg-dir "state" ".local" "share") "aiu-editor"))

;; cache-dir returns the editor's cache directory.
(define (cache-dir)
  (build-path (xdg-dir "cache" ".cache") "aiu-editor"))

;; ensure-dir creates a directory when it is missing, and says so when it
;; cannot, so a caller never writes into a path that is not there.
(define (ensure-dir d)
  (cond
    [(directory-exists? d) d]
    [else
     (with-handlers
         ([exn:fail?
           (lambda (e)
             (error-of 'err-no-directory "the editor" (path->string d)
                       "the directory could not be created"
                       "check the permissions of the directory above it"))])
       (make-directory* d)
       d)]))
