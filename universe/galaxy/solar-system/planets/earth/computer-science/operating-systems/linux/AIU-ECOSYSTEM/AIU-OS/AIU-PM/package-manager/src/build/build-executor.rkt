#lang racket/base
;; build-executor.rkt -- the step EXECUTOR protocol: one word from the
;; closed vocabulary runs one step; the plural runs a recipe in order
;; and stops at the first failure; the host-tool preflight runs before
;; the first step. This is the one file in build/ that SPAWNS: the
;; build-systems modules hand it an exe, argv and cwd, and spawn-build!
;; runs them through run.rkt with kind 'build errors. Copy is native and
;; returns void.

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "../process/run.rkt"
         "../errors/error-type.rkt"
         "../spec/spec.rkt"
         "../narration/narration.rkt"
         "build-env.rkt"
         "build-systems/make.rkt"
         "build-systems/cmake.rkt"
         "build-systems/configure.rkt"
         "build-systems/cargo.rkt"
         "build-systems/run.rkt")

(provide
 ;; build-step plus dirs -> void, one vocabulary word or kind 'config
 execute-build-step
 ;; (listof build-step) plus dirs -> void, in order, stops at failure
 execute-build-steps
 ;; (listof string) -> void, or kind 'config naming the missing tool
 require-host-tools)

;; The closed list, mirroring spec-read's valid-steps (E-08).
(define valid-build-steps
  '(cmake-build cmake-configure cmake-install configure copy make
                make-info cargo run))

;; ---------------------------------------------------------------------------
;; One spawn. The build-systems modules build the command; this runs it
;; and owns every spawn error, mirroring local-perform.rkt's run-step:
;; missing exe or cwd is kind 'config, nonzero exit is kind 'build with
;; the tail.

;; string (listof env) -> (or/c path #f), a bare exe as the build
;; sees it: the PATH override wins when the caller sets one, so stubs
;; beat ambient tools; else the ambient PATH
(define (find-build-exe exe extras)
  (define hit (assoc "PATH" extras))
  (if hit
      (let loop ([rest (string-split (cdr hit) ":")])
        (cond [(null? rest) #f]
              [(file-exists? (build-path (car rest) exe))
               (build-path (car rest) exe)]
              [else (loop (cdr rest))]))
      (find-executable-path exe)))

;; string (listof string) path string (listof env) -> void
(define (spawn-build! exe argv cwd step-name extras)
  (define prog
    (if (regexp-match? #rx"/" exe)
        (let ([p (if (absolute-path? (string->path exe))
                     (string->path exe)
                     (build-path cwd exe))])
          (if (file-exists? p)
              p
              (raise-pm-error
               'config 'execute-build-step
               "step executable not found"
               #:fields `(("exe" . ,exe)
                           ("step" . ,step-name)))))
        (or (find-build-exe exe extras)
            (raise-pm-error
             'config 'execute-build-step
             "step executable not found"
             #:fields `(("exe" . ,exe)
                         ("step" . ,step-name))))))
  (unless (directory-exists? cwd)
    (raise-pm-error 'config 'execute-build-step
                    "step directory missing"
                    #:fields `(("step" . ,step-name)
                               ("directory" . ,(path->string cwd)))))
  (define res
    (spawn-and-wait prog argv
                 #:cwd cwd
                 #:kind 'build
                 #:operation step-name
                 #:env extras))
  (unless (zero? (result-exit res))
    (raise-pm-error 'build 'execute-build-step "step failed"
                    #:fields `(("step" . ,step-name)
                                ("command" . ,(string-join
                                               (cons exe argv) " "))
                                ("directory" . ,(path->string cwd))
                                ("exit-code" . ,(number->string
                                                 (result-exit res)))
                                ("stderr" . ,(string-join
                                              (result-stderr-lines res)
                                              "\n"))))))

;; ---------------------------------------------------------------------------
;; Native copy: bytes move inside the work root, no process at all.

;; (listof any) path path string -> void, native copy
(define (copy-step! args work source step-name)
  (define rels (filter string? args))
  (unless (= 2 (length rels))
    (raise-pm-error 'config 'execute-build-step
                    "copy needs SRC DST"
                    #:fields `(("step" . ,step-name))))
  (define src (resolve-dir 'copy (first rels) work source))
  (define dst-rel (second rels))
  (check-confined dst-rel 'copy)
  (define dst (build-path work dst-rel))
  (unless (or (file-exists? src) (directory-exists? src))
    (raise-pm-error 'config 'execute-build-step
                    "copy source missing"
                    #:fields `(("step" . ,step-name)
                                ("src" . ,(path->string src)))))
  (make-directory* (or (path-only dst) work))
  (when (file-exists? dst) (delete-file dst))
  (when (directory-exists? dst) (delete-directory/files dst))
  (if (directory-exists? src)
      (copy-directory/files src dst)
      (copy-file src dst)))

;; ---------------------------------------------------------------------------
;; Entry points: one step dispatches on the step name; the plural runs
;; a list in order and stops at the first failure.

;; build-step #:source #:work #:prefix [#:env] -> void
(define (execute-build-step s
                            #:source source
                            #:work work
                            #:prefix prefix
                            #:env [overrides '()])
  (define name (build-step-name s))
  (define args (build-step-args s))
  (define prefix-s (if (path? prefix)
                       (path->string prefix)
                       prefix))
  (define extras
    (append (build-env #:prefix prefix-s
                       #:source (if (path? source)
                                    (path->string source)
                                    source)
                       #:work (if (path? work)
                                  (path->string work)
                                  work))
            overrides))
  (define (spawn-step! exe argv dir)
    (spawn-build! exe argv dir (symbol->string name) extras))
  (case name
    [(copy) (copy-step! args work source "copy")]
    [(make)
     (define-values (exe argv dir) (make-command args work source))
     (spawn-step! exe argv dir)]
    [(make-info)
     (define-values (exe argv dir) (make-info-command args work source))
     (spawn-step! exe argv dir)]
    [(cmake-configure)
     (define-values (exe argv dir)
       (cmake-configure-command args work source prefix-s))
     (spawn-step! exe argv dir)]
    [(cmake-build)
     (define-values (exe argv dir) (cmake-build-command args work source))
     (spawn-step! exe argv dir)]
    [(cmake-install)
     (define-values (exe argv dir) (cmake-install-command args work source))
     (spawn-step! exe argv dir)]
    [(configure)
     (define-values (exe argv dir) (configure-command args work source))
     (spawn-step! exe argv dir)]
    [(cargo)
     (define-values (exe argv dir) (cargo-command args work source))
     (spawn-step! exe argv dir)]
    [(run)
     (define-values (exe argv dir)
       (run-step-command args work source prefix-s))
     (spawn-step! exe argv dir)]
    [else
     (raise-pm-error
      'config 'execute-build-step
      (format "unknown build step '~a (valid: ~a)" name
              (string-join (map symbol->string valid-build-steps) " "))
      #:fields `(("step" . ,(format "~a" name))))]))

;; (listof string) -> void. Host-tool preflight (E-25). Every tool
;; named by an ecosystem must resolve on PATH BEFORE the first step
;; runs, so a missing compiler costs nothing instead of half a build.
;; Raises kind 'config naming the tool; nothing is spawned here.
(define (require-host-tools tools)
  (for ([t (in-list tools)])
    (define exe (and (find-executable-path t) #t))
    (unless (and exe (file-exists? (find-executable-path t)))
      (raise-pm-error
       'config 'require-host-tools
       (format "required tool not on PATH: ~a" t)
       #:fields `(("tool" . ,t)
                  ("hint" . ,(format "install ~a or fix PATH before building" t)))))))

;; (listof build-step) #:source #:work #:prefix [#:env] [#:tools] -> void
(define (execute-build-steps steps
                             #:source source
                             #:work work
                             #:prefix prefix
                             #:env [overrides '()]
                             #:tools [tools '()])
  (require-host-tools tools)
  ;; D-036: one op around the whole recipe, one narrated step per entry
  ;; in it. This is the choke point every build and install goes
  ;; through, so narrating here covers both without touching each one.
  (with-op 'build
           (string-append (number->string (length steps)) " build step(s)")
           "the spec named these build steps and they must run in order"
           #:how (string-join (map (lambda (s) (symbol->string (build-step-name s))) steps) " ")
           #:inputs (map (lambda (s) (symbol->string (build-step-name s))) steps)
           (lambda ()
             (for ([s (in-list steps)])
               (step 'build
                     (symbol->string (build-step-name s))
                     "the next step of this spec's build recipe"
                     #:how (string-join
                              (map (lambda (a)
                                     (if (keyword? a)
                                         (keyword->string a)
                                         (format "~a" a)))
                                   (build-step-args s))
                              " "))
               (execute-build-step s
                                   #:source source
                                   #:work work
                                   #:prefix prefix
                                   #:env overrides)))))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           "../errors/error-type.rkt")

  ;; All fixtures are synthetic (T-10) under one temp root: tiny
  ;; Makefiles using only printf, stub configure/cargo/cmake scripts
  ;; in shell, real sh for run. Nothing reads the real home or XDG.
  (define test-root (build-path (find-system-path 'temp-dir)
                                "pm-build-test"))
  (when (directory-exists? test-root)
    (delete-directory/files test-root))
  (make-directory* test-root)
  (define prefix-dir (build-path test-root "prefix"))
  (make-directory* prefix-dir)

  ;; string string -> void, write a text fixture
  (define (write-fixture path content)
    (call-with-output-file path
      (lambda (out) (display content out))
      #:exists 'truncate/replace))

  ;; path string -> void, shell stub plus the executable bit
  (define (write-stub path content)
    (write-fixture path content)
    (file-or-directory-permissions path #o755))

  ;; path-string path-string -> (listof env), stub bin first on PATH
  (define (stub-env bin)
    (list (cons "PATH" (string-append (path->string bin)
                                      ":"
                                      (getenv "PATH")))))

  ;; copy moves bytes inside the work root.
  (define work-copy (build-path test-root "w-copy"))
  (make-directory* work-copy)
  (write-fixture (build-path work-copy "a.txt") "alpha")
  (execute-build-step (build-step 'copy '("a.txt" "b.txt"))
                      #:source work-copy
                      #:work work-copy
                      #:prefix prefix-dir)
  (check-equal? (file->string (build-path work-copy "b.txt")) "alpha")

  ;; make runs the all target with real make (present here).
  (define work-make (build-path test-root "w-make"))
  (make-directory* work-make)
  (write-fixture (build-path work-make "makefile")
                 "all:\n\tprintf built > out.txt\n")
  (execute-build-step (build-step 'make '(#:dir "."
                                          #:file "makefile"
                                          #:targets ("all")))
                      #:source work-make
                      #:work work-make
                      #:prefix prefix-dir)
  (check-equal? (file->string (build-path work-make "out.txt")) "built")

  ;; make-info runs its own target word through the same make.
  (define work-info (build-path test-root "w-info"))
  (make-directory* work-info)
  (write-fixture (build-path work-info "makefile")
                 "info:\n\tprintf docs > info.txt\n")
  (execute-build-step (build-step 'make-info '(#:dir "."
                                               #:targets ("info")))
                      #:source work-info
                      #:work work-info
                      #:prefix prefix-dir)
  (check-equal? (file->string (build-path work-info "info.txt")) "docs")

  ;; run executes argv without a shell; sh -c spells shell work.
  (define work-run (build-path test-root "w-run"))
  (make-directory* work-run)
  (execute-build-step (build-step 'run '(#:argv ("sh" "-c"
                                                 "printf ran > ran.txt")
                                         #:dir "."))
                      #:source work-run
                      #:work work-run
                      #:prefix prefix-dir)
  (check-equal? (file->string (build-path work-run "ran.txt")) "ran")

  ;; run expands $PREFIX to the staging prefix before spawning.
  (define work-pfx (build-path test-root "w-pfx"))
  (make-directory* work-pfx)
  (execute-build-step (build-step 'run '(#:argv ("sh" "-c"
                                                 "printf hi > \"$PREFIX/hit.txt\"")
                                         #:dir "."))
                      #:source work-pfx
                      #:work work-pfx
                      #:prefix prefix-dir)
  (check-equal? (file->string (build-path prefix-dir "hit.txt")) "hi")

  ;; configure runs the dir's own script with its args.
  (define work-cfg (build-path test-root "w-cfg"))
  (make-directory* work-cfg)
  (write-stub (build-path work-cfg "configure")
              "#!/bin/sh\nprintf ok > configured.txt\n")
  (execute-build-step (build-step 'configure '(#:dir "."
                                               #:args ("--flag")))
                      #:source work-cfg
                      #:work work-cfg
                      #:prefix prefix-dir)
  (check-equal? (file->string (build-path work-cfg "configured.txt"))
                "ok")

  ;; Stub bin for the words whose tools are missing here (cmake,
  ;; cargo): synthetic sh scripts, first on PATH for these calls.
  (define stub-bin (build-path test-root "bin"))
  (make-directory* stub-bin)
  (write-stub (build-path stub-bin "cmake")
              (string-append "#!/bin/sh\n"
                             "echo \"$@\" >> cmake.log\n"
                             "if printf '%s' \" $* \" | grep -q ' --install '; then\n"
                             "  mkdir -p \"$PREFIX\"\n"
                             "  printf ok > \"$PREFIX/cmake-installed.txt\"\n"
                             "fi\n"
                             "printf x >> cmake.count\n"))
  (write-stub (build-path stub-bin "cargo")
              "#!/bin/sh\necho \"$@\" > cargo-args.txt\nprintf ok > cargo-ran.txt\n")
  (define extras (stub-env stub-bin))

  ;; cargo passes its args through in the step dir.
  (define work-cargo (build-path test-root "w-cargo"))
  (make-directory* work-cargo)
  (execute-build-step (build-step 'cargo '(#:dir "." #:args ("build")))
                      #:source work-cargo
                      #:work work-cargo
                      #:prefix prefix-dir
                      #:env extras)
  (check-equal? (file->string (build-path work-cargo "cargo-ran.txt"))
                "ok")

  ;; The three cmake words each reach the stub with distinct argv.
  (define work-cmake (build-path test-root "w-cmake"))
  (make-directory* work-cmake)
  (execute-build-steps
   (list (build-step 'cmake-configure
                     '(#:srcdir "." #:builddir "build"
                       #:defines (("FLAG_A" "OFF"))))
         (build-step 'cmake-build '(#:builddir "build"))
         (build-step 'cmake-install '(#:builddir "build")))
   #:source work-cmake
   #:work work-cmake
   #:prefix prefix-dir
   #:env extras)
  (check-equal? (length (file->lines (build-path work-cmake "cmake.log")))
                3)
  (check-equal? (file->string (build-path prefix-dir
                                          "cmake-installed.txt"))
                "ok")

  ;; The plural runs a list in order and stops at failure: copy
  ;; lands, then the bad run raises kind 'build.
  (define work-seq (build-path test-root "w-seq"))
  (make-directory* work-seq)
  (write-fixture (build-path work-seq "s.txt") "s")
  (check-pred build-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (execute-build-steps
                 (list (build-step 'copy '("s.txt" "d.txt"))
                       (build-step 'run '(#:argv ("sh" "-c" "exit 3")
                                          #:dir ".")))
                 #:source work-seq
                 #:work work-seq
                 #:prefix prefix-dir)
                'no-error))
  (check-equal? (file->string (build-path work-seq "d.txt")) "s")

  ;; Outside the closed vocabulary is kind 'config, never silent.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (execute-build-step (build-step 'frobnicate '())
                                    #:source work-seq
                                    #:work work-seq
                                    #:prefix prefix-dir)
                'no-error))

  ;; Host-tool preflight (E-25): a missing tool refuses with kind
  ;; 'config BEFORE any step runs, and sh (always present) passes.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (require-host-tools '("sh" "pm-no-such-tool-xyz"))
                'no-error))
  (check-true
   (with-handlers ([exn:fail:pm? (lambda (e) #f)])
     (require-host-tools '("sh"))
     #t))
  ;; The preflight runs before step one: a copy that would succeed
  ;; still refuses when the tool list is unsatisfiable.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (execute-build-steps (list (build-step 'copy '("a.txt" "z.txt")))
                                     #:source work-copy
                                     #:work work-copy
                                     #:prefix prefix-dir
                                     #:tools '("pm-no-such-tool-xyz"))
                'no-error))
  (check-false (file-exists? (build-path work-copy "z.txt")))

  (delete-directory/files test-root))
