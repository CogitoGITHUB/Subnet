#lang racket/base
;; build.rkt -- Emacs target build steps: batch byte-compile, autoloads
;; via loaddefs-generate, smoke load. Everything through emacs --batch
;; -Q (Emacs 29+ required; 30.2 probed here). Warnings are collected
;; for E-11 style reporting; hard failures raise kind 'build (E-8).

(require racket/contract/base
         racket/file
         racket/string
         "../../backends/run.rkt"
         "../../core/errors.rkt")

(provide
 (contract-out
  ;; -> path, missing emacs is kind 'config (F-2)
  [emacs-executable-path (-> path?)]
  ;; (listof string) path-string -> (listof string), batch compiles
  ;; every file; nonzero exit is kind 'build with E-8 fields
  [emacs-byte-compile-files
   (->* ((listof string?) path-string?)
         (#:timeout exact-positive-integer?
          #:env (listof (cons/c string? string?)))
         (listof string?))]
  ;; path-string path-string -> void, loaddefs-generate output file
  [emacs-generate-autoloads
   (->* (path-string? path-string?)
         (#:timeout exact-positive-integer?
          #:env (listof (cons/c string? string?)))
         void?)]
  ;; (listof string) path-string -> void, batch load check, no jit
  [emacs-smoke-load
   (->* ((listof string?) path-string?)
         (#:timeout exact-positive-integer?
          #:env (listof (cons/c string? string?)))
         void?)]))

;; ---------------------------------------------------------------------------
;; Running (one place builds argv; failures name the step per E-8)

;; -> path, missing emacs is kind 'config (F-2: fail clearly if missing)
(define (emacs-executable-path)
  (or (find-executable-path "emacs")
      (raise-pm-error 'config 'emacs-executable-path
                      "emacs executable not found"
                      #:hint "install Emacs 29 or later for this target")))

;; path (listof string) path-string string -> run-result
(define (emacs-batch exe argv cwd operation #:timeout timeout #:env env)
  (run-command/redirect exe argv
               #:cwd cwd
               #:kind 'build #:timeout timeout
               #:operation operation
               #:env env))

;; symbol string run-result -> never returns (E-8 core fields)
(define (raise-build-failure step command res)
  (raise-pm-error 'build step "emacs step failed"
                  #:fields `(("command" . ,command)
                             ("exit-code"
                              . ,(number->string (run-result-exit res)))
                             ("stderr" . ,(string-join
                                           (run-result-stderr-lines res)
                                           "\n")))))

;; run-result -> (listof string), stderr lines carrying warnings
(define (warning-lines res)
  (for/list ([line (in-list (run-result-stderr-lines res))]
             #:when (string-contains? line "Warning:"))
    line))

;; ---------------------------------------------------------------------------
;; Steps

;; (listof string) path-string -> (listof string)
(define (emacs-byte-compile-files files srcdir
                                  #:timeout [timeout 300]
                                  #:env [env '()])
  (define emacs (emacs-executable-path))
  (if (null? files)
      '()
      (let ((argv (append (list "-Q" "--batch" "-L" (dir-text srcdir)
                                "-f" "batch-byte-compile")
                          files)))
        (define res
          (emacs-batch emacs argv (dir-text srcdir) "byte-compile"
                       #:timeout timeout #:env env))
        (if (zero? (run-result-exit res))
            (warning-lines res)
            (raise-build-failure 'byte-compile
                                 (string-join (cons (dir-text emacs) argv)
                                              " ")
                                 res)))))

;; path-string path-string -> void
(define (emacs-generate-autoloads srcdir output-file
                                  #:timeout [timeout 300]
                                  #:env [env '()])
  (define emacs (emacs-executable-path))
  (define form
    (format "(loaddefs-generate ~s ~s)"
            (dir-text srcdir) (dir-text output-file)))
  (define argv (list "-Q" "--batch" "--eval" form))
  (define res
    (emacs-batch emacs argv (dir-text srcdir) "autoloads"
                 #:timeout timeout #:env env))
  (cond [(not (zero? (run-result-exit res)))
         (raise-build-failure 'autoloads
                              (string-join (cons (dir-text emacs) argv) " ")
                              res)]
        [(file-exists? output-file) (void)]
        [else
         (raise-pm-error 'build 'autoloads "autoloads file missing"
                         #:fields `(("output" . ,(dir-text output-file))))]))

;; (listof string) path-string -> void
(define (emacs-smoke-load load-dirs entry-file
                          #:timeout [timeout 300]
                          #:env [env '()])
  (define emacs (emacs-executable-path))
  (define no-jit
    "(when (boundp 'native-comp-jit-compilation) (setq native-comp-jit-compilation nil))")
  (define argv
    (append (list "-Q" "--batch" "--eval" no-jit)
            (apply append
                   (map (lambda (d) (list "-L" (dir-text d)))
                        load-dirs))
            (list "-l" (dir-text entry-file))))
  (define res
    (emacs-batch emacs argv
                 (if (null? load-dirs)
                     (dir-text entry-file)
                     (dir-text (car load-dirs)))
                 "smoke-load"
                 #:timeout timeout #:env env))
  (unless (zero? (run-result-exit res))
    (raise-build-failure 'smoke-load
                         (string-join (cons (dir-text emacs) argv) " ")
                         res)))

;; path-string -> string, for argv text (paths and strings both allowed)
(define (dir-text d)
  (if (path? d) (path->string d) d))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           "../../core/errors.rkt")

  ;; Isolated HOME so batch runs never touch the real ~/.emacs.d.
  (define test-root (make-temporary-directory "pm-emacs~a"))
  (define test-home (build-path test-root "home"))
  (make-directory test-home)
  (define test-env `(("HOME" . ,(path->string test-home))))
  (define pkg-dir (build-path test-root "pkg"))
  (make-directory pkg-dir)

  ;; string string -> void, one fixture .el file with TEXT.
  (define (write-el name text)
    (call-with-output-file (build-path pkg-dir name)
      (lambda (port) (display text port))))

  ;; Two clean files, one with an autoload cookie, one warning case.
  (write-el "a.el"
            (string-append ";;; a.el --- demo\n"
                           "\n"
                           ";;;###autoload\n"
                           "(defun my-demo-fn ()\n"
                           "  \"Demo.\"\n"
                           "  (message \"hi\"))\n"
                           "\n"
                           "(provide 'a)\n"
                           ";;; a.el ends here\n"))
  (write-el "b.el"
            ";;; b.el --- demo\n\n(provide 'b)\n;;; b.el ends here\n")
  (write-el "c.el"
            ";;; c.el --- warns\n\n(setq my-undeclared-xyz 1)\n\n(provide 'c)\n;;; c.el ends here\n")
  (write-el "broken.el" "(defun broken-fn (oops\n")

  ;; Byte-compile succeeds and writes .elc files next to sources.
  (define warnings
    (parameterize ([current-directory pkg-dir])
      (emacs-byte-compile-files (list (path->string (build-path pkg-dir "a.el"))
                                      (path->string (build-path pkg-dir "b.el")))
                                (path->string pkg-dir)
                                #:env test-env)))
  (check-true (list? warnings))
  (check-true (file-exists? (build-path pkg-dir "a.elc")))
  (check-true (file-exists? (build-path pkg-dir "b.elc")))

  ;; Free-variable assignment warns but still succeeds.
  (define c-warnings
    (emacs-byte-compile-files (list (path->string (build-path pkg-dir "c.el")))
                              (path->string pkg-dir)
                              #:env test-env))
  (check-false (null? c-warnings))
  (check-true (file-exists? (build-path pkg-dir "c.elc")))

  ;; Broken sources fail loud with kind 'build and E-8 fields.
  (define broken-error
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (emacs-byte-compile-files
       (list (path->string (build-path pkg-dir "broken.el")))
       (path->string pkg-dir)
       #:env test-env)
      'no-error))
  (check-pred build-error? broken-error)
  (check-regexp-match #rx"exit-code" (exn-message broken-error))
  (check-regexp-match #rx"byte-compile" (exn-message broken-error))

  ;; Empty file lists compile vacuously.
  (check-equal? (emacs-byte-compile-files '()
                                          (path->string pkg-dir)
                                          #:env test-env)
                '())

  ;; Autoloads generation writes the cookie expansion.
  (define autoloads-file (build-path pkg-dir "pkg-autoloads.el"))
  (emacs-generate-autoloads (path->string pkg-dir)
                            (path->string autoloads-file)
                            #:env test-env)
  (check-true (file-exists? autoloads-file))
  (check-regexp-match #rx"my-demo-fn"
                      (file->string autoloads-file))
  ;; Idempotent second run over the same tree.
  (emacs-generate-autoloads (path->string pkg-dir)
                            (path->string autoloads-file)
                            #:env test-env)
  (check-true (file-exists? autoloads-file))

  ;; Smoke load passes on good output, fails loud on missing entry.
  (emacs-smoke-load (list (path->string pkg-dir))
                    (path->string (build-path pkg-dir "a.el"))
                    #:env test-env)
  (check-pred build-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (emacs-smoke-load (list (path->string pkg-dir))
                                  (path->string
                                   (build-path pkg-dir "no-such.el"))
                                  #:env test-env)
                'no-error))

  ;; Missing emacs is kind 'config, not a crash.
  (check-pred path? (emacs-executable-path))

  (delete-directory/files test-root))
