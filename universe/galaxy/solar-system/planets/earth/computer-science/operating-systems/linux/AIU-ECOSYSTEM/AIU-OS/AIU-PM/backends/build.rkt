#lang racket/base
;; build.rkt -- execute the closed build-step vocabulary (ENGINE.org
;; backends/build.rkt, SPEC-NEUTRAL section 2, D-025).
;;
;; The build environment attaches HERE, not in the action: build-env
;; builds the extras passed to run-command (LANG, a fake HOME, PREFIX,
;; SRCDIR, BUILDDIR). PATH and CC come from the parent through run.rkt's
;; allowlist; this module never reads the environment itself, and no
;; HOME, XDG or find-system-path appears outside the tests. Relative
;; step dirs resolve under the work root first (the caller exports the
;; source tree there) and fall back to the source dir; absolute paths
;; and .. escapes refuse with kind 'config. Unknown step names refuse
;; with kind 'config naming the valid list, like spec-read.
;; Spawned steps print pm-run-start/pm-run-end through run.rkt, so no
;; step is silent; copy is native and returns void.

(require racket/contract/base
         racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "run.rkt"
         "../core/errors.rkt"
         "../core/spec.rkt"
         "../core/verbose.rkt")

(provide
 (contract-out
  ;; keyword dirs -> env extras for run-command (D-025, SPEC-NEUTRAL 5)
  [build-env (-> #:prefix path-string?
                 #:source path-string?
                 #:work path-string?
                 (listof (cons/c string? string?)))]
  ;; build-step plus dirs -> void, one vocabulary word or kind 'config
  [execute-build-step
   (->* (build-step?
         #:source path-string?
         #:work path-string?
         #:prefix path-string?)
        (#:env (listof (cons/c string? string?)))
        void?)]
  ;; (listof build-step) plus dirs -> void, in order, stops at failure.
  ;; #:tools is the ecosystem host-tool list (E-25): checked BEFORE the
  ;; first step, so a missing compiler fails before anything is built.
  [execute-build-steps
   (->* ((listof build-step?)
         #:source path-string?
         #:work path-string?
         #:prefix path-string?)
        (#:env (listof (cons/c string? string?))
         #:tools (listof string?))
        void?)]
  ;; (listof string) -> void, or kind 'config naming the missing tool
  [require-host-tools (-> (listof string?) void?)]))

;; The closed list, mirroring spec-read's valid-steps (E-08).
(define valid-build-steps
  '(cmake-build cmake-configure cmake-install configure copy make
                make-info cargo run))

;; ---------------------------------------------------------------------------
;; Small datum helpers (spec args are plain data: keywords, strings,
;; lists of strings or pairs).

;; (listof any) keyword any -> any, value after KW or DEFAULT
(define (arg-val args kw default)
  (let loop ([rest args])
    (cond [(null? rest) default]
          [(and (keyword? (car rest)) (equal? (car rest) kw))
           (if (pair? (cdr rest)) (cadr rest) default)]
          [else (loop (cdr rest))])))

;; any -> (listof string), single string counts as one
(define (as-strings v)
  (cond [(string? v) (list v)]
        [(list? v) (filter string? v)]
        [else '()]))

;; any string -> string
(define (as-string v default)
  (if (string? v) v default))

;; any -> (listof string), NAME=VALUE flags from pairs or bare strings
(define (pairs->flags v flag-prefix)
  (cond [(list? v)
         (for/list ([item (in-list v)]
                    #:when (or (string? item)
                               (and (list? item)
                                    (= 2 (length item)))))
           (if (string? item)
               (if (string-prefix? item flag-prefix)
                   item
                   (string-append flag-prefix item))
               (string-append flag-prefix
                              (format "~a=~a" (first item)
                                      (second item)))))]
        [else '()]))

;; any -> (listof string), NAME=VALUE without a prefix
(define (vars->flags v)
  (cond [(list? v)
         (for/list ([item (in-list v)]
                    #:when (or (string? item)
                               (and (list? item)
                                    (= 2 (length item)))))
           (if (string? item)
               item
               (format "~a=~a" (first item) (second item))))]
        [else '()]))

;; string string -> string, every $PREFIX becomes the prefix path
(define (expand-prefix s prefix)
  (string-replace s "$PREFIX" prefix))

;; ---------------------------------------------------------------------------
;; Path discipline: work first, source as fallback; builddir always
;; under work; absolute paths and .. escapes refuse (kind 'config).

;; string -> void, absolute or escaping paths never run
(define (check-confined rel step-name)
  (define p (string->path rel))
  (when (or (absolute-path? p)
            (member 'up (explode-path p)))
    (raise-pm-error 'config 'execute-build-step
                    "step path escapes the work root"
                    #:fields `(("step" . ,(symbol->string step-name))
                               ("path" . ,rel)))))

;; symbol string path path -> path, work first then source
(define (resolve-dir step-name rel work source)
  (check-confined rel step-name)
  (define w (build-path work rel))
  (if (or (directory-exists? w) (file-exists? w))
      w
      (build-path source rel)))

;; string path -> path, build outputs always live under work
(define (resolve-builddir rel work step-name)
  (check-confined rel step-name)
  (define b (build-path work rel))
  (make-directory* b)
  b)

;; ---------------------------------------------------------------------------
;; Environment (D-025, SPEC-NEUTRAL section 5): LANG, a staging-fake
;; HOME inside work, and the three directory pointers. PATH reaches the
;; child through run.rkt's allowlist; callers add overrides via #:env.

;; #:prefix #:source #:work -> env extras
(define (build-env #:prefix prefix #:source source #:work work)
  (define home (build-path work "fake-home"))
  (make-directory* home)
  ;; G-09: builds run without ambient network configuration. The proxy
  ;; variables are emptied (not merely dropped: an empty proxy means no
  ;; proxy to every tool that reads them), so a build cannot reach the
  ;; network through the user's proxy setup and cannot present ambient
  ;; proxy credentials. Blocking direct connections needs a sandbox pm
  ;; does not have; that limit is stated in ENGINE.org, not hidden.
  (append (list (cons "LANG" "C.UTF-8")
                (cons "HOME" (path->string home))
                (cons "PREFIX" (if (path? prefix)
                                   (path->string prefix)
                                   prefix))
                (cons "SRCDIR" (if (path? source)
                                   (path->string source)
                                   source))
                (cons "BUILDDIR" (if (path? work)
                                     (path->string work)
                                     work)))
          (for/list ([v (in-list '("http_proxy" "https_proxy"
                                   "HTTP_PROXY" "HTTPS_PROXY"))])
            (cons v ""))))

;; ---------------------------------------------------------------------------
;; One spawn, mirroring local.rkt's run-step errors: missing exe or
;; cwd is kind 'config, nonzero exit is kind 'build with the tail.

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
    (run-command prog argv
                 #:cwd cwd
                 #:kind 'build
                 #:operation step-name
                 #:env extras))
  (unless (zero? (run-result-exit res))
    (raise-pm-error 'build 'execute-build-step "step failed"
                    #:fields `(("step" . ,step-name)
                                ("command" . ,(string-join
                                               (cons exe argv) " "))
                                ("directory" . ,(path->string cwd))
                                ("exit-code" . ,(number->string
                                                 (run-result-exit res)))
                                ("stderr" . ,(string-join
                                              (run-result-stderr-lines res)
                                              "\n"))))))

;; ---------------------------------------------------------------------------
;; One word each. Every helper takes the datum args plus the three
;; dirs and the merged extras, and returns void.

;; (listof any) path path string (listof env) -> void, native copy
(define (do-copy! args work source step-name extras)
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

;; (listof any) path path string (listof env) -> void, make
(define (do-make! args work source step-name extras)
  (define dir (resolve-dir 'make (as-string (arg-val args '#:dir ".")
                                            ".")
                           work source))
  (define file (arg-val args '#:file #f))
  (define targets (as-strings (arg-val args '#:targets '())))
  (define vars (vars->flags (arg-val args '#:vars '())))
  (define jobs (arg-val args '#:jobs #f))
  (define argv
    (append (if (string? file) (list "-f" file) '())
            targets
            vars
            (if (or (integer? jobs) (string? jobs))
                (list (string-append "-j" (format "~a" jobs)))
                '())))
  (spawn-build! "make" argv dir "make" extras))

;; (listof any) path path string (listof env) -> void, doc make
(define (do-make-info! args work source step-name extras)
  (define dir (resolve-dir 'make-info (as-string (arg-val args '#:dir ".")
                                                 ".")
                           work source))
  (define targets (as-strings (arg-val args '#:targets '())))
  (spawn-build! "make" targets dir "make-info" extras))

;; (listof any) path path string (listof env) -> void, cmake configure
(define (do-cmake-configure! args work source step-name extras prefix)
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
  (spawn-build! "cmake"
                (append (list "-S" (path->string src)
                              "-B" (path->string bld))
                        defs
                        (list (string-append "-DCMAKE_INSTALL_PREFIX="
                                             prefix)))
                work
                "cmake-configure"
                extras))

;; (listof any) path path string (listof env) -> void, cmake build
(define (do-cmake-build! args work source step-name extras)
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
  (spawn-build! "cmake"
                (append (list "--build" (path->string bld))
                        job-flags
                        target-flags)
                work
                "cmake-build"
                extras))

;; (listof any) path path string (listof env) -> void, cmake install
(define (do-cmake-install! args work source step-name extras)
  (define bld-rel (as-string (arg-val args '#:builddir "build") "build"))
  (check-confined bld-rel 'cmake-install)
  (define bld (build-path work bld-rel))
  (spawn-build! "cmake"
                (list "--install" (path->string bld))
                work
                "cmake-install"
                extras))

;; (listof any) path path string (listof env) -> void, ./configure
(define (do-configure! args work source step-name extras)
  (define dir (resolve-dir 'configure (as-string (arg-val args '#:dir ".")
                                                 ".")
                           work source))
  (define flags (as-strings (arg-val args '#:args '())))
  (spawn-build! (path->string (build-path dir "configure"))
                flags
                dir
                "configure"
                extras))

;; (listof any) path path string (listof env) -> void, cargo
(define (do-cargo! args work source step-name extras)
  (define dir (resolve-dir 'cargo (as-string (arg-val args '#:dir ".")
                                             ".")
                           work source))
  (define flags (as-strings (arg-val args '#:args '())))
  (spawn-build! "cargo" flags dir "cargo" extras))

;; (listof any) path path string (listof env) -> void, escape hatch
(define (do-run! args work source step-name extras prefix)
  (define raw-argv (as-strings (arg-val args '#:argv '())))
  (when (null? raw-argv)
    (raise-pm-error 'config 'execute-build-step
                    "run needs #:argv"
                    #:fields `(("step" . ,step-name))))
  (define dir (resolve-dir 'run (as-string (arg-val args '#:dir ".")
                                            ".")
                           work source))
  (define argv (map (lambda (a) (expand-prefix a prefix)) raw-argv))
  (spawn-build! (first argv) (rest argv) dir "run" extras))

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
  (case name
    [(copy) (do-copy! args work source "copy" extras)]
    [(make) (do-make! args work source "make" extras)]
    [(make-info) (do-make-info! args work source "make-info" extras)]
    [(cmake-configure)
     (do-cmake-configure! args work source "cmake-configure" extras
                          prefix-s)]
    [(cmake-build) (do-cmake-build! args work source "cmake-build"
                                    extras)]
    [(cmake-install) (do-cmake-install! args work source "cmake-install"
                                        extras)]
    [(configure) (do-configure! args work source "configure" extras)]
    [(cargo) (do-cargo! args work source "cargo" extras)]
    [(run) (do-run! args work source "run" extras prefix-s)]
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
           "../core/errors.rkt")

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

  ;; G-09: the build env carries no ambient network configuration.
  ;; Proxy variables are present but empty, so no proxy (and no proxy
  ;; credentials) reaches a build step.
  (define benv (build-env #:prefix prefix-dir
                          #:source work-copy
                          #:work work-copy))
  (for ([v (in-list '("http_proxy" "https_proxy"
                       "HTTP_PROXY" "HTTPS_PROXY"))])
    (check-equal? (cdr (assoc v benv)) ""))
  (delete-directory/files test-root))
