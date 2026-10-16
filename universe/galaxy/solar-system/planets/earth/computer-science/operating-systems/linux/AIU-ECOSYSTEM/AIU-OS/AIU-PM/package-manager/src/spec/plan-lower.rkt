#lang racket/base
;; plan-lower.rkt -- turns package-plans into action lists in stage order
;; and renders them as stable text. It must not derive, hash or judge
;; spec conflicts.

(require racket/string
         "../errors/error-type.rkt"
         "../security/security.rkt"
         "spec.rkt"
         "../entry/version.rkt"
         "plan-actions.rkt"
         "plan-hash.rkt")

(provide
 ;; build-step string -> run-step-action, one closed-vocabulary step
 lower-one-step
 ;; install form string string (or/c exact-integer? #f)
 ;; -> (list action ... exact-int-or-#f), one form lowered plus the
 ;; mode state for the forms after it
 lower-one-install
 ;; (listof install-form) string string -> (listof action), check form
 ;; skipped (it becomes the one check-action); mode forms thread state
 lower-install-forms
 ;; package-plan x4 string -> (listof action), one package, stage order
 lower-package-plan
 ;; (listof package-plan) x4 string lists -> (listof action), deps-first
 ;; order kept, shared identities emitted once (E-06)
 lower-plans
 ;; action -> string, one line
 action->line
 ;; plan -> string, one line per action in order, stable for goldens
 plan->text
 ;; package-plan -> string, stable multi-line rendering for goldens
 package-plan->text)

;; ---------------------------------------------------------------------------
;; Lowering (E-06: package plan -> actions in stage order)
;;
;; Per package: fetch, export, mark-incomplete, build steps, install
;; actions, check (only when the plan has a check form), clear-incomplete,
;; set-current. Check runs after placement and before the marker is
;; cleared (D-028). Dirs arrive as strings (layout is the caller's
;; knowledge: D-023 store dirs, D-029 scope roots); lowering itself is pure.
;; run-step argv is the step name plus the flattened string args, except
;; for run steps, whose argv is the command as written: prepending "run"
;; made every run step look for an executable named "run", so no run
;; step could ever perform (E-08 tightening, found by the first real
;; pm-apply run).

;; build-step string -> run-step-action, one closed-vocabulary step
(define (lower-one-step s staging)
  (define strings
    (let loop ([args (build-step-args s)] [out '()])
      (cond [(null? args) (reverse out)]
            [(string? (car args)) (loop (cdr args) (cons (car args) out))]
            [(list? (car args))
             (loop (cdr args)
                   (append (reverse (filter string? (car args))) out))]
            [else (loop (cdr args) out)])))
  (run-step-action (symbol->string (build-step-name s))
                   (if (eq? (build-step-name s) 'run)
                       strings
                       (cons (symbol->string (build-step-name s)) strings))
                   staging))

;; install form string string (or/c exact-integer? #f)
;; -> (list action ... exact-int-or-#f), one form lowered plus the
;; mode state for the forms after it. SPEC-NEUTRAL section 3: bin and
;; libexec default to 755, the rest to 644, until a (mode ...) form
;; says otherwise (E-12b: the first real build caught bin at 644).
(define (lower-one-install form staging versioned mode)
  (define kind (car form))
  (define args (cdr form))
  (define (kind-default k)
    (if (or (eq? k 'bin) (eq? k 'libexec)) #o755 #o644))
  (case kind
    [(bin lib include share man libexec)
     (define rels (filter string? args))
     (define dst (if (and (pair? rels) (pair? (cdr rels)))
                     (cadr rels)
                     (car rels)))
     (list (install-file-action (string-append staging "/"
                                               (car rels))
                                (string-append versioned "/" dst)
                                (or mode (kind-default kind)))
           mode)]
    [(copy-tree)
     (list (install-file-action (string-append staging "/" (car args))
                                (string-append versioned "/" (cadr args))
                                #o755)
           mode)]
    [(symlink)
     (list (symlink-action (string-append versioned "/" (cadr args))
                           (string-append versioned "/" (car args)))
           mode)]
    [(mode)
     ;; S-01: a requested mode outside 755 and 644 refuses here, at the
     ;; lowering step, rather than being widened or narrowed downstream.
     (define want (cadr args))
     (unless (install-mode-allowed? want)
       (raise-pm-error 'spec 'lower-package-plan "install mode refused"
                       #:fields `(("mode" . ,(format "~s" want)))
                       #:hint "pm writes only 755 and 644"))
     (list #f want)]
    [else
     (raise-pm-error 'internal 'lower-package-plan "unknown install form"
                     #:fields `(("form" . ,(format "~s" form))))]))

;; (listof install-form) string string -> (listof action), check form
;; skipped (it becomes the one check-action); mode forms thread state
(define (lower-install-forms forms staging versioned)
  (define-values (actions _mode)
    (for/fold ([out '()] [mode #f]) ([form (in-list forms)])
      (if (and (pair? form) (eq? (car form) 'check))
          (values out mode)
          (let ((lowered (lower-one-install form staging versioned mode)))
            (values (if (car lowered)
                        (append out (list (car lowered)))
                        out)
                    (cadr lowered))))))
  actions)

;; package-plan string string string string -> (listof action), one
;; package in stage order; the url travels beside the plan because plans
;; carry pins (D-007), not locations
(define (lower-package-plan pp url staging versioned current)
  (define steps
    (for/list ([s (in-list (package-plan-steps pp))])
      (lower-one-step s staging)))
  (define installs
    (lower-install-forms (install-spec-forms (package-plan-install pp))
                         staging versioned))
  (define check
    (if (package-plan-check pp)
        (list (check-action (cdr (package-plan-check pp)) versioned))
        '()))
  (append (list (fetch-action url
                              (package-plan-commit pp)
                              staging)
                (export-action (package-plan-name pp)
                               (package-plan-commit pp)
                               staging)
                (mark-incomplete-action versioned))
          steps
          installs
          check
          (list (clear-incomplete-action versioned)
                (set-current-action versioned current))))

;; (listof package-plan) x4 string lists -> (listof action), input order
;; kept (deps first from derive-plans), shared identities emitted once
(define (lower-plans pps urls stagings versioneds currents)
  (define n (length pps))
  (unless (and (= (length urls) n)
               (= (length stagings) n)
               (= (length versioneds) n)
               (= (length currents) n))
    (raise-pm-error 'internal 'lower-plans "parallel lists differ"
                    #:fields `(("plans" . ,(format "~a" n))
                               ("urls" . ,(format "~a" (length urls))))))
  (define seen (make-hash))
  (for/fold ([out '()]) ([pp (in-list pps)]
                         [url (in-list urls)]
                         [staging (in-list stagings)]
                         [versioned (in-list versioneds)]
                         [current (in-list currents)])
    (define id (package-plan-identity pp))
    (if (hash-has-key? seen id)
        out
        (begin (hash-set! seen id #t)
               (append out (lower-package-plan pp url staging
                                               versioned current))))))

;; ---------------------------------------------------------------------------
;; Rendering (stable text for dry-run output and golden files)

;; package-plan -> string, stable multi-line rendering for goldens
(define (package-plan->text pp)
  (string-join
   (list (format "package ~a ~a slot ~a commit ~a"
                 (package-plan-name pp)
                 (version->string (package-plan-version pp))
                 (package-plan-slot pp)
                 (package-plan-commit pp))
         (format "flags: ~a"
                 (string-join
                  (for/list ([f (in-list (package-plan-flags pp))])
                    (format "~a=~a" (car f) (cdr f)))
                  " "))
         (format "deps: ~a"
                 (string-join (package-plan-deps pp) ", "))
         (format "steps: ~a"
                 (string-join
                  (for/list ([s (in-list (package-plan-steps pp))])
                    (format "~a" (build-step-name s)))
                  " "))
         (format "install: ~a" (install-spec-target
                                (package-plan-install pp)))
         (format "check: ~a"
                 (if (package-plan-check pp) "present" "absent"))
         (format "input-hash: ~a" (package-plan-input-hash pp)))
   "\n"))

;; action -> string, one line
(define (action->line a)
  (cond [(fetch-action? a)
         (format "fetch ~a @ ~a -> ~a"
                 (fetch-action-url a)
                 (fetch-action-commit a)
                 (fetch-action-dest a))]
        [(extract-action? a)
         (format "extract ~a -> ~a"
                 (extract-action-src a) (extract-action-dest a))]
        [(run-step-action? a)
         (format "run-step ~a [~a] in ~a"
                 (run-step-action-name a)
                 (string-join (run-step-action-argv a) " ")
                 (run-step-action-cwd a))]
        [(install-file-action? a)
         (format "install-file ~a -> ~a mode ~a"
                 (install-file-action-src a)
                 (install-file-action-dest a)
                 (number->string (install-file-action-mode a) 8))]
        [(write-file-action? a)
         (format "write-file ~a (~a bytes)"
                 (write-file-action-path a)
                 (string-length (write-file-action-content a)))]
        [(symlink-action? a)
         (format "symlink ~a -> ~a"
                 (symlink-action-link a) (symlink-action-target a))]
        [(remove-path-action? a)
         (format "remove-path ~a" (remove-path-action-path a))]
        [(export-action? a)
         (format "export ~a @ ~a -> ~a"
                 (export-action-package a)
                 (export-action-pin a)
                 (export-action-dest a))]
        [(check-action? a)
         (format "check [~a] in ~a"
                 (string-join (check-action-argv a) " ")
                 (check-action-cwd a))]
        [(mark-incomplete-action? a)
         (format "mark-incomplete ~a" (mark-incomplete-action-dir a))]
        [(clear-incomplete-action? a)
         (format "clear-incomplete ~a" (clear-incomplete-action-dir a))]
        [(set-current-action? a)
         (format "set-current ~a -> ~a"
                 (set-current-action-link a)
                 (set-current-action-target a))]
        [else (raise-pm-error 'internal 'action->line "not an action"
                              #:fields `(("value" . ,a)))]))

;; plan -> string, one line per action in order, stable for goldens
(define (plan->text p)
  (string-join (map action->line (plan-actions p)) "\n"))

;; ---------------------------------------------------------------------------
;; The renderer is the stable surface goldens compare against, so its
;; tests run here. The plans they render come from plan-derive.rkt (one
;; file down), which is where a plan is built in the first place.

(module+ test
  (require racket/list
           rackunit
           "../errors/error-type.rkt"
           "spec.rkt"
           "../entry/version.rkt"
           "plan-derive.rkt")

  ;; Every action builds and predicates sort them.
  (define fetch-1
    (fetch-action "https://example.org/r.git" (make-string 40 #\a) "/tmp/s"))

  ;; Golden: a hand-built plan renders to stable text.
  (define golden-plan
    (list->plan
     (list fetch-1
           (export-action 'demo (make-string 40 #\a) "/tmp/s")
           (extract-action "/tmp/s" "/tmp/stage")
           (run-step-action "compile" '("make" "-j4") "/tmp/stage")
           (install-file-action "/tmp/stage/a.el" "/pkg/a.el" #o644)
           (write-file-action "/pkg/pin" "9edb3f66")
           (symlink-action "/pkg/1.0" "/pkg/current")
           (remove-path-action "/tmp/stage")
           (mark-incomplete-action "/pkg/1.0")
           (check-action '("bin/demo" "--version") "/pkg/1.0")
           (clear-incomplete-action "/pkg/1.0")
           (set-current-action "/pkg/1.0" "/pkg/current"))))
  (check-equal?
   (plan->text golden-plan)
   (string-join
    (list (string-append "fetch https://example.org/r.git @ "
                         (make-string 40 #\a) " -> /tmp/s")
          (string-append "export demo @ " (make-string 40 #\a)
                         " -> /tmp/s")
          "extract /tmp/s -> /tmp/stage"
          "run-step compile [make -j4] in /tmp/stage"
          "install-file /tmp/stage/a.el -> /pkg/a.el mode 644"
          "write-file /pkg/pin (8 bytes)"
          "symlink /pkg/current -> /pkg/1.0"
          "remove-path /tmp/stage"
          "mark-incomplete /pkg/1.0"
          "check [bin/demo --version] in /pkg/1.0"
          "clear-incomplete /pkg/1.0"
          "set-current /pkg/current -> /pkg/1.0")
    "\n"))

  ;; Empty plan renders empty.
  (check-equal? (plan->text (list->plan '())) "")

  ;; E-04 fixtures: pkg-alpha on pkg-beta, synthetic and local (T-10).
  (define alpha-spec
    (spec 'pkg-alpha (string->version "2.0") "Alpha"
          (source "https://example.org/alpha.git"
                  "9edb3f66fd807b096b48283debdcddccfea34bad")
          (list (dep 'pkg-beta (string->version "1.0")))
          '()
          (list (build-step 'copy '("a" "b")))
          (install-spec 'prefix '((bin "alpha" "bin/alpha")
                                  (check "bin/alpha" "--version")))
          'mit "https://example.org/alpha" #f '() '()
          'default
          (list (flag-spec 'gui #t "GUI" '() '()))))
  (define beta-spec
    (spec 'pkg-beta (string->version "1.0") "Beta"
          (source "https://example.org/beta.git"
                  "8edb3f66fd807b096b48283debdcddccfea34bad")
          '() '()
          (list (build-step 'copy '("c" "d")))
          (install-spec 'prefix '((bin "beta" "bin/beta")))
          'mit "https://example.org/beta" #f '() '()
          'default
          '()))
  (define alpha-plan
    (derive-package-plan alpha-spec '((gui . #t)) '("pkg-beta 1.0")))
  (define beta-plan
    (derive-package-plan beta-spec '() '()))

  ;; Golden plan text for both packages.
  (check-equal?
   (package-plan->text alpha-plan)
   (string-join
    (list (string-append "package pkg-alpha 2.0 slot default commit "
                         "9edb3f66fd807b096b48283debdcddccfea34bad")
          "flags: gui=#t"
          "deps: pkg-beta 1.0"
          "steps: copy"
          "install: prefix"
          "check: present"
          (string-append "input-hash: "
                         (package-plan-input-hash alpha-plan)))
    "\n"))
  (check-equal?
   (package-plan->text beta-plan)
   (string-join
    (list (string-append "package pkg-beta 1.0 slot default commit "
                         "8edb3f66fd807b096b48283debdcddccfea34bad")
          "flags: "
          "deps: "
          "steps: copy"
          "install: prefix"
          "check: absent"
          (string-append "input-hash: "
                         (package-plan-input-hash beta-plan)))
    "\n"))

  ;; E-06 lowering fixtures: gamma depends on alpha (T-10).
  (define gamma-spec
    (spec 'pkg-gamma (string->version "3.0") "Gamma"
          (source "https://example.org/gamma.git"
                  "7edb3f66fd807b096b48283debdcddccfea34bad")
          (list (dep 'pkg-alpha (string->version "2.0")))
          '()
          (list (build-step 'copy '("e" "f")))
          (install-spec 'prefix '((bin "gamma" "bin/gamma")))
          'mit "https://example.org/gamma" #f '() '()
          'default
          '()))
  (define gamma-plan
    (derive-package-plan gamma-spec '() '("pkg-alpha 2.0")))
  ;; per-package dirs, synthetic and distinct (T-10)
  (define beta-dirs
    (list "https://example.org/beta.git" "/tmp/stage-beta"
          "/pkg/beta/1.0" "/pkg/beta/current"))
  (define alpha-dirs
    (list "https://example.org/alpha.git" "/tmp/stage-alpha"
          "/pkg/alpha/2.0" "/pkg/alpha/current"))
  (define gamma-dirs
    (list "https://example.org/gamma.git" "/tmp/stage-gamma"
          "/pkg/gamma/3.0" "/pkg/gamma/current"))

  ;; Exact action sequence for one package without a check form.
  (check-equal?
   (plan->text
    (list->plan
     (apply lower-package-plan beta-plan beta-dirs)))
   (string-join
    (list (string-append "fetch https://example.org/beta.git @ "
                         "8edb3f66fd807b096b48283debdcddccfea34bad"
                         " -> /tmp/stage-beta")
          (string-append "export pkg-beta @ "
                         "8edb3f66fd807b096b48283debdcddccfea34bad"
                         " -> /tmp/stage-beta")
          "mark-incomplete /pkg/beta/1.0"
          "run-step copy [copy c d] in /tmp/stage-beta"
          (string-append "install-file /tmp/stage-beta/beta"
                         " -> /pkg/beta/1.0/bin/beta mode 755")
          "clear-incomplete /pkg/beta/1.0"
          "set-current /pkg/beta/current -> /pkg/beta/1.0")
    "\n"))

  ;; The check runs after placement and before the marker is cleared.
  (define alpha-actions
    (apply lower-package-plan alpha-plan alpha-dirs))
  (define alpha-text (plan->text (list->plan alpha-actions)))
  (check-regexp-match
   #rx"install-file.*\ncheck \\[bin/alpha --version\\] in /pkg/alpha/2.0\nclear-incomplete"
   alpha-text)

  ;; No verify action anywhere in lowered output.
  (check-false (regexp-match? #rx"(^|\n)verify " alpha-text))
  (check-false (ormap (lambda (a) (and (install-file-action? a)
                                      (= (install-file-action-mode a)
                                         #o000)))
                      alpha-actions))

  ;; Deps first: lower-plans keeps input order, so callers hand over
  ;; deps-first lists (derive-plans returns that order); beta before
  ;; alpha before gamma, stable across runs.
  (define trio-once
    (lower-plans (list beta-plan alpha-plan gamma-plan)
                 (list (car beta-dirs) (car alpha-dirs) (car gamma-dirs))
                 (list (cadr beta-dirs) (cadr alpha-dirs) (cadr gamma-dirs))
                 (list (caddr beta-dirs) (caddr alpha-dirs) (caddr gamma-dirs))
                 (list (cadddr beta-dirs) (cadddr alpha-dirs)
                       (cadddr gamma-dirs))))
  (define (first-index pred xs)
    (let loop ([i 0] [rest xs])
      (cond [(null? rest) #f]
            [(pred (car rest)) i]
            [else (loop (+ i 1) (cdr rest))])))
  (define trio-text (plan->text (list->plan trio-once)))
  (check-true (< (first-index (lambda (a) (and (fetch-action? a)
                                              (string=? (fetch-action-commit a)
                                                        "8edb3f66fd807b096b48283debdcddccfea34bad")))
                             trio-once)
                 (first-index (lambda (a) (and (fetch-action? a)
                                              (string=? (fetch-action-commit a)
                                                        "9edb3f66fd807b096b48283debdcddccfea34bad")))
                             trio-once)))
  (check-true (< (first-index (lambda (a) (and (fetch-action? a)
                                              (string=? (fetch-action-commit a)
                                                        "9edb3f66fd807b096b48283debdcddccfea34bad")))
                             trio-once)
                 (first-index (lambda (a) (and (fetch-action? a)
                                              (string=? (fetch-action-commit a)
                                                        "7edb3f66fd807b096b48283debdcddccfea34bad")))
                             trio-once)))
  (check-equal? (plan->text (list->plan trio-once)) trio-text)

  ;; A shared dependency lowered twice appears once.
  (define trio-twice
    (lower-plans (list beta-plan alpha-plan gamma-plan beta-plan)
                 (list (car beta-dirs) (car alpha-dirs)
                       (car gamma-dirs) (car beta-dirs))
                 (list (cadr beta-dirs) (cadr alpha-dirs)
                       (cadr gamma-dirs) (cadr beta-dirs))
                 (list (caddr beta-dirs) (caddr alpha-dirs)
                       (caddr gamma-dirs) (caddr beta-dirs))
                 (list (cadddr beta-dirs) (cadddr alpha-dirs)
                       (cadddr gamma-dirs) (cadddr beta-dirs))))
  (check-equal? (length (filter fetch-action? trio-twice)) 3)
  (check-equal? (plan->text (list->plan trio-twice)) trio-text)

  ;; Parallel lists of different lengths are caller error.
  (check-pred internal-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (lower-plans (list beta-plan) '() '() '() '())
                'no-error))

  ;; S-02: a spec-requested mode outside 755 and 644 refuses with the
  ;; rule's message, at lowering time, never downstream.
  (define mode-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (lower-one-install '(mode "bin/x" 777) "/stage" "/ver" #f)
      'no-error))
  (check-pred spec-error? mode-err)
  (check-regexp-match #rx"install mode refused" (exn-message mode-err))
  (check-equal? (lower-one-install '(mode "bin/x" 493) "/stage" "/ver" #f)
                (list #f 493)))
