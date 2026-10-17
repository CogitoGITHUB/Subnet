#lang racket/base
;; ecosystem-file-test.rkt -- the moved-out test submodule of src/spec/ecosystem-file.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            racket/path
            racket/string
            "../../src/errors/error-type.rkt"
            "../../src/spec/spec.rkt"
            "../../src/spec/spec-read.rkt"
         "../../src/spec/ecosystem-file.rkt")

(module+ test
  (require rackunit
           racket/file
           racket/runtime-path
           "../../src/spec/spec-read.rkt"
           "../../src/spec/spec.rkt")

  ;; The shipped files read as themselves. core/ is this file's dir,
  ;; its parent is the repo root where ecosystems/ and docs/ live.
  (define-runtime-path core-dir ".")
  ;; Three ups, not one: src/spec -> src -> package-manager -> the repo
  ;; root, which is where ecosystems/ actually lives. One up landed on
  ;; package-manager and the fixture was simply not there.
  (define-values (root _here _here-dir?)
    (values (simplify-path (build-path core-dir 'up 'up 'up)) #f #f))
  (define (rooted rel) (path->string (build-path root rel)))
  (define make-c (read-ecosystem-file (rooted "ecosystems/make-c.rktd")))
  (check-equal? (ecosystem-name make-c) 'make-c)
  (check-equal? (ecosystem-tools make-c) '("make" "cc"))
  (check-equal? (ecosystem-steps make-c)
                (list (build-step 'make
                                  '(#:dir "." #:file "makefile"
                                    #:targets ("all")))))
  (define cargo (read-ecosystem-file (rooted "ecosystems/cargo.rktd")))
  (check-equal? (ecosystem-name cargo) 'cargo)
  (check-equal? (ecosystem-tools cargo) '("cargo"))

  ;; No overrides: the template itself. With overrides: same-name
  ;; replaces in place, new names append.
  (check-equal? (expand-steps make-c '()) (ecosystem-steps make-c))
  (check-equal? (expand-steps make-c
                             (list (build-step 'make
                                              '(#:dir "."
                                                #:file "makefile"
                                                #:targets ("install")))
                                   (build-step 'run
                                              '(#:argv ("echo hi")
                                                #:dir "."))))
                (list (build-step 'make
                                  '(#:dir "." #:file "makefile"
                                    #:targets ("install")))
                      (build-step 'run
                                  '(#:argv ("echo hi") #:dir "."))))

  ;; The make-c template is exactly lua.rktd's hand-written steps.
  (check-equal? (ecosystem-steps make-c)
                (spec-build (read-spec-file (rooted "docs/examples/lua.rktd"))))

  ;; The checklist's bar: a spec naming make-c expands to the SAME
  ;; plan as the hand-written steps, and names the tools to preflight.
  (define-values (lua-tools lua-steps)
    (expand-spec make-c (read-spec-file (rooted "docs/examples/lua.rktd"))))
  (check-equal? lua-tools '("make" "cc"))
  (check-equal? lua-steps (spec-build (read-spec-file
                                       (rooted "docs/examples/lua.rktd"))))
  (check-equal? lua-steps (ecosystem-steps make-c))
  (define-values (cargo-tools cargo-steps)
    (expand-spec cargo (read-spec-file (rooted "docs/examples/lua.rktd"))))
  (check-equal? cargo-tools '("cargo"))
  (check-equal? cargo-steps
                (list (build-step 'cargo '(#:dir "." #:args ("build" "--release")))
                      (build-step 'make '(#:dir "." #:file "makefile"
                                                #:targets ("all")))))

  ;; Bad files refuse with kind 'spec naming the file.
  (define bad-root (build-path (find-system-path 'temp-dir)
                               "pm-eco-test"))
  (when (directory-exists? bad-root)
    (delete-directory/files bad-root))
  (make-directory* bad-root)
  (define (write-bad name content)
    (define p (build-path bad-root name))
    (call-with-output-file p (lambda (out) (display content out)))
    (path->string p))
  (define (spec-fails? path)
    (with-handlers ([exn:fail:pm?
                     (lambda (e)
                       (and (spec-error? e)
                            (regexp-match? #rx"eco"
                                           (path->string bad-root))))])
      (read-ecosystem-file path)
      #f))
  (define bad-bodies
    '(("bad-step.rktd" "(ecosystem (name bad-step) (tools ()) (build (steps (frobnicate))))")
      ("bad-field.rktd" "(ecosystem (name bad-field) (tools ()) (build (steps)) (extra 1))")
      ("bad-name.rktd" "(ecosystem (name 42) (tools ()) (build (steps)))")
      ("other.rktd" "(ecosystem (name mismatch) (tools ()) (build (steps)))")))
  (for ([pair (in-list bad-bodies)])
    (check-true (spec-fails? (write-bad (car pair) (cadr pair)))))
  (delete-directory/files bad-root))

