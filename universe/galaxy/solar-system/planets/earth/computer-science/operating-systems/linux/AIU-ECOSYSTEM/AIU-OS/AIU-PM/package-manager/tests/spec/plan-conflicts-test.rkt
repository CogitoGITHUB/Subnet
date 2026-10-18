#lang racket/base
;; plan-conflicts-test.rkt -- the suite for spec/plan-conflicts.rkt: the
;; destinations a spec claims, and the refusal when two claim one (G-01).
;; Step 14 of TODO.org phase A: this suite lived inline in the module.
;; Here it also drives the refusal through the plan path the =plan=
;; command runs, because "fails at plan time" is a promise about the
;; command, not about one function -- a unit test of the checker alone
;; would keep passing if the command stopped calling it.
;;
;; The require list is the module's OWN list (racket/file and rackunit
;; for the fixture directory) plus the names the fixture and the plan
;; path need: entry/version.rkt's string->version, documents.rkt's
;; plan-document and git-env.rkt's current-allow-file-urls, the
;; parameter the specs are read under (D-046: the module's list, minus
;; whatever it re-provides, plus the module itself).

(require rackunit
         racket/file
         "../../src/errors/error-type.rkt"
         "../../src/git/git-env.rkt"
         "../../src/spec/spec.rkt"
         "../../src/spec/plan-conflicts.rkt"
         "../../src/entry/documents.rkt")

(module+ test
  (require rackunit
           racket/file
           "../../src/errors/error-type.rkt"
           "../../src/spec/spec.rkt"
           "../../src/entry/version.rkt")

  ;; E-04 fixture: pkg-alpha claims bin/alpha and owns one check form
  ;; (T-10), the same declaration plan-derive.rkt turns into a plan.
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

  ;; G-01, unit: dests mirror lowering (second rel wins); a shared
  ;; destination refuses with kind 'activate naming both packages.
  (check-equal? (spec-install-dests alpha-spec) '("bin/alpha"))
  (define clash-a
    (struct-copy spec alpha-spec
                 [name 'pkg-clash-a]
                 [install (install-spec 'prefix '((bin "tool" "bin/tool")))]))
  (define clash-b
    (struct-copy spec alpha-spec
                 [name 'pkg-clash-b]
                 [install (install-spec 'prefix '((bin "tool" "bin/tool")))]))
  (check-true (with-handlers ([exn:fail:pm? (lambda (e) #f)])
                (check-spec-conflicts (list alpha-spec clash-a))
                #t))
  (define clash-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (check-spec-conflicts
       (list clash-a clash-b
             (struct-copy spec alpha-spec
                          [name 'pkg-clash-c]
                          [install (install-spec 'prefix '((bin "tool")))])))
      'no-error))
  (check-pred activate-error? clash-err)
  (check-regexp-match #rx"pkg-clash-a" (exn-message clash-err))
  (check-regexp-match #rx"pkg-clash-b" (exn-message clash-err))
  (check-regexp-match #rx"bin/tool" (exn-message clash-err))
  ;; mode and check own nothing: a check form never joins the dest list
  ;; even when it names the very path another package installs.
  (check-equal? (spec-install-dests
                 (struct-copy spec alpha-spec
                              [install (install-spec
                                        'prefix
                                        '((check "bin/tool" "--version")))]))
                '())

  ;; ------------------------------------------------------------------
  ;; G-01 at the plan: two real .rktd files on disk, read by the same
  ;; plan-document the =plan= command calls, in both directions.
  ;; ------------------------------------------------------------------

  ;; symbol string -> string, one spec declaration line-for-line
  (define (spec-text name install-form)
    (string-append
     (format "(spec (format-version 2) (name ~a) (version \"1.0\")" name)
     " (summary \"a fixture package\")"
     " (source (git \"https://example.org/x.git\""
     " \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     " (build (steps (copy \"a\" \"b\")))"
     install-form
     " (license mit) (homepage \"https://example.org\"))"))

  ;; (listof (cons symbol string)) -> path, a directory of .rktd files
  (define (write-specs-dir specs)
    (define dir (make-temporary-directory "pm-g01-specs~a"))
    (for ([s (in-list specs)])
      (call-with-output-file (build-path dir (format "~a.rktd" (car s)))
        (lambda (port)
          (displayln (spec-text (car s) (cdr s)) port))))
    dir)

  ;; path -> (or/c (listof jsexpr) exn:fail:pm?), the plan or the refusal
  (define (plan-or-refusal dir)
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (parameterize ([current-allow-file-urls #t])
        (plan-document (path->string dir)))))

  (define tool-bin " (install (prefix (bin \"tool\" \"bin/tool\")))")
  (define clash-dir
    (write-specs-dir (list (cons 'pkg-a tool-bin)
                           (cons 'pkg-b tool-bin))))
  (define clash-plan (plan-or-refusal clash-dir))
  (check-pred exn:fail:pm? clash-plan)
  (check-equal? (exn:fail:pm-kind clash-plan) 'activate)
  ;; both packages named, in one message: a reader must not have to
  ;; re-run anything to learn which two collided.
  (check-regexp-match #rx"pkg-a and pkg-b both claim bin/tool"
                      (exn-message clash-plan))
  (check-equal? (exn:fail:pm-fields clash-plan)
                '(("path" . "bin/tool")
                  ("owned-by" . "pkg-a")
                  ("claimed-by" . "pkg-b")))
  ;; nothing landed: the refusal happens before a single destination is
  ;; touched, so the directory still holds exactly the two specs.
  ;; directory-list yields names for this directory (measured in the
  ;; gate run), so compare names, not build-path forms.
  (check-equal? (sort (map path->string (directory-list clash-dir)) string<?)
                '("pkg-a.rktd" "pkg-b.rktd"))

  ;; the same two packages with their own paths plan: the refusal above
  ;; is about the collision, not about having two packages.
  (define clean-dir
    (write-specs-dir
     (list (cons 'pkg-a tool-bin)
           (cons 'pkg-b " (install (prefix (bin \"other\" \"bin/other\")))"))))
  (define clean-plan (plan-or-refusal clean-dir))
  (check-pred list? clean-plan)
  (check-equal? (map (lambda (p) (hash-ref p 'name)) clean-plan)
                '("pkg-a" "pkg-b"))
  (check-equal? (map (lambda (p) (hash-ref p 'version)) clean-plan)
                '("1.0" "1.0"))
  ;; every package in the directory enters the plan, deps included
  (check-equal? (length clean-plan) 2))
