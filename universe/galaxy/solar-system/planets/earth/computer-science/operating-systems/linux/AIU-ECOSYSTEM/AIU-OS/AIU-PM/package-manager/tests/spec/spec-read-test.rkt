#lang racket/base
;; spec-read-test.rkt -- the moved-out test submodule of src/spec/spec-read.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, minus whatever the module itself re-provides, plus the
;; module itself: this body could already see everything it uses,
;; so nothing new can reach in.

(require rackunit
   racket/contract/base
            racket/list
            racket/port
            racket/runtime-path
            "../../src/errors/error-type.rkt"
            "../../src/spec/spec.rkt"
            "../../src/spec/spec-typos.rkt"
            ;; rackunit also provides fail; inside the module these
            ;; tests came from, the test submodule's rackunit shadowed
            ;; the outer copy, so the copied module gives it up (D-046).
            (except-in "../../src/spec/spec-fields.rkt" fail)
            "../../src/spec/spec-source.rkt"
            ;; spec-build-steps.rkt goes too: spec-read.rkt
            ;; re-provides valid-build-step? and step-required-keys,
            ;; and this body calls none of its other two names (D-046).
         "../../src/spec/spec-read.rkt")

(module+ test
  (require rackunit
           racket/file
           "../../src/errors/error-type.rkt"
           "../../src/spec/spec.rkt"
           "../../src/spec/version.rkt")

  ;; S-03: every negative fixture in docs/examples-bad refuses with its
  ;; rule's own name. These files are the declarations pm must never
  ;; accept, and this test is what keeps them honest.
  (define-runtime-path spec-core-dir
    "."
  )
  (define bad-dir
    (simplify-path
      (build-path spec-core-dir 'up 'up 'up "docs" "examples-bad"
      )
    )
  )
  (define bad-cases
    (list
      (cons "bad-pin.rktd" "source-trust"
      )
      (cons "bad-url.rktd" "origin"
      )
      (cons "bad-path.rktd" "path-escape"
      )
      (cons "bad-mode.rktd" "install-mode"
      )
    )
  )
  (for
    (
      [pair (in-list bad-cases)
      ]
    )
    (define err
      (with-handlers
        (
          [exn:fail:pm? (lambda (e) e)
          ]
        )
        (read-spec-file
          (path->string
            (build-path bad-dir (car pair)
            )
          )
        )
        'no-error
      )
    )
    (check-pred spec-error? err (car pair)
    )
    (check-regexp-match
      (regexp
        (string-append "\\[" (cdr pair) "\\]"
        )
      )
      (exn-message err
      )
      (car pair
      )
    )
  )

  ;; string (listof string) -> path, fixture file in a fresh temp dir
  (define (write-fixture name lines)
    (define dir (make-temporary-directory "pm-spec~a"))
    (call-with-output-file (build-path dir name)
      (lambda (out)
        (for ([line (in-list lines)])
          (displayln line out))))
    dir)

  ;; (listof string) -> string, the full pm message (or NO-ERROR)
  (define (message-for lines)
    (define dir (write-fixture "pkg.rktd" lines))
    (define result
      (parameterize ([current-directory dir])
        (with-handlers ([exn:fail:pm? exn-message])
          (read-spec-file "pkg.rktd")
          "NO-ERROR")))
    (delete-directory/files dir)
    result)

  ;; Full golden spec exercises every field.
  (define golden-dir
    (write-fixture
     "golden.rktd"
     '("(spec"
       "  (format-version 2)"
       "  (name demo)"
       "  (version \"2.9.1\")"
       "  (summary \"demo package\")"
       "  (source (git \"https://example.org/demo.git\""
       "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
       "  (deps ((pkg-beta \"1.0\")))"
       "  (build-deps ((pkg-gamma \"2.0\")))"
       "  (build (steps (copy \"a\" \"b\")))"
       "  (install (prefix (bin \"demo\" \"bin/demo\") (check \"bin/demo\")))"
       "  (license gpl-3.0+)"
       "  (homepage \"https://example.org/demo\")"
       "  (extends base)"
       "  (variants ((lite (version \"1.0\"))))"
       "  (when (platform linux) ((version \"1.0\"))))")))
  (define golden
    (parameterize ([current-directory golden-dir])
      (read-spec-file "golden.rktd")))
  (check-true (spec? golden))
  (check-equal? (spec-name golden) 'demo)
  (check-equal? (version->string (spec-version golden)) "2.9.1")
  (check-equal? (source-commit (spec-source golden))
                "9edb3f66fd807b096b48283debdcddccfea34bad")
  (check-equal? (map dep-name (spec-deps golden)) '(pkg-beta))
  (check-equal? (map dep-name (spec-build-deps golden)) '(pkg-gamma))
  (check-equal? (build-step-name (car (spec-build golden))) 'copy)
  (check-equal? (install-spec-target (spec-install golden)) 'prefix)
  (check-equal? (length (install-spec-forms (spec-install golden))) 2)
  (check-equal? (spec-extends golden) 'base)
  (check-equal? (length (spec-variants golden)) 1)
  (check-equal? (length (spec-whens golden)) 1)
  (delete-directory/files golden-dir)

  ;; Minimal spec: deps, extends, variants and whens default out.
  (define minimal-dir
    (write-fixture
     "minimal.rktd"
     '("(spec"
       "  (format-version 2)"
       "  (name tiny)"
       "  (version \"1.0\")"
       "  (summary \"tiny\")"
       "  (source (git \"https://example.org/t.git\""
       "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
       "  (build (steps (copy \"a\" \"b\")))"
       "  (install (prefix (bin \"b\")))"
       "  (license mit)"
       "  (homepage \"https://example.org/t\"))")))
  (define minimal
    (parameterize ([current-directory minimal-dir])
      (read-spec-file "minimal.rktd")))
  (check-equal? (spec-deps minimal) '())
  (check-false (spec-extends minimal))
  (check-equal? (spec-variants minimal) '())
  (check-equal? (spec-whens minimal) '())
  (delete-directory/files minimal-dir)

  ;; Exact message 1: unknown key at 3:4, with a suggestion.
  (check-equal?
   (message-for '("(spec" "  (format-version 2)" "  (soruce \"x\"))"))
   (string-append "read-spec: invalid declaration;\n"
                  "  at: pkg.rktd:3:4\n"
                  "  hint: unknown key 'soruce (did you mean 'source?)"))

  ;; Exact message 1b: a v1 spec is rejected, never silently accepted.
  (check-equal?
   (message-for '("(spec" "  (format-version 1)" "  (name demo)"
                  "  (version \"1.0\")" "  (summary \"s\")"
                  "  (source (git \"https://example.org/d.git\""
                  "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
                  "  (build (steps (copy \"a\" \"b\")))"
                  "  (install (prefix (bin \"b\")))"
                  "  (license mit)"
                  "  (homepage \"https://example.org\"))"))
   (string-append "read-spec: invalid declaration;\n"
                  "  at: pkg.rktd:2:19\n"
                  "  hint: unsupported format-version 1 (neutral spec needs 2; see "
                  "docs/SPEC-NEUTRAL.org section 9)"))

  ;; G-12: a v9 spec gets the same rule's own message, not a field error.
  (check-equal?
   (message-for '("(spec" "  (format-version 9)" "  (name demo)"
                  "  (version \"1.0\")" "  (summary \"s\")"
                  "  (source (git \"https://example.org/d.git\""
                  "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
                  "  (build (steps (copy \"a\" \"b\")))"
                  "  (install (prefix (bin \"b\")))"
                  "  (license mit)"
                  "  (homepage \"https://example.org\"))"))
   (string-append "read-spec: invalid declaration;\n"
                  "  at: pkg.rktd:2:19\n"
                  "  hint: unsupported format-version 9 (neutral spec needs 2; see "
                  "docs/SPEC-NEUTRAL.org section 9)"))

  ;; Exact message 2: bad version value at 4:11.
  (check-equal?
   (message-for '("(spec" " (format-version 2)"
                  " (name demo)" " (version \"1..2\"))"))
   (string-append "read-spec: invalid declaration;\n"
                  "  at: pkg.rktd:4:11\n"
                  "  hint: invalid version \"1..2\""))

  ;; Exact message 3: missing source points at the top form.
  (check-equal?
   (message-for '("(spec" "  (format-version 2)" "  (name demo)"
                  "  (version \"1.0\")" "  (summary \"s\")"
                  "  (build (steps (copy \"a\" \"b\")))"
                  "  (install (prefix (bin \"b\")))"
                  "  (license mit)"
                  "  (homepage \"https://example.org\"))"))
   (string-append "read-spec: invalid declaration;\n"
                  "  at: pkg.rktd:1:1\n"
                  "  hint: missing required field 'source"))

  ;; Hostile inputs: every kind is 'spec with a telling hint.
  (define (hint-matches? lines pattern)
    (check-regexp-match pattern (message-for lines)))
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\" \"xyz\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"\\[source-trust\\] not a commit id")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"ext::sh -c true\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"\\[origin\\] rejected git URL")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name a)" "  (name b))")
   #rx"duplicate field")
  (hint-matches?
   '("(package" "  (name a))")
   #rx"expected \\(spec")
  (hint-matches? '("(((") #rx"cannot read declaration")
  (hint-matches? '() #rx"empty declaration")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (frobnicate)))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   (regexp (string-append "unknown build step 'frobnicate \\(valid: "
                           "cmake-build cmake-configure cmake-install configure "
                           "copy make make-info cargo run\\)")))
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (make #:dir \".\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"step 'make needs #:targets")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"../etc/passwd\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"\\[path-escape\\] install path '../etc/passwd escapes the prefix")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\") (mode \"bin/b\" 777)))"
     "  (license mit)" "  (homepage \"https://example.org\"))")
   #rx"\\[install-mode\\] mode 777 refused")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (check \"bin/a\") (check \"bin/b\")))"
     "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"only one check form per install")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (web ((x 1))))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"install must be")
  (hint-matches?
   '("(spec" "  (format-version 3)" "  (name demo))")
   #rx"unsupported format-version")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (deps ((pkg-beta)))" "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))")
   #rx"dep must be")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\")"
     "  (when (os linux) ((version \"1.0\"))))")
   #rx"unknown condition")
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\")"
     "  (variants ((lite (name other)))))")
   #rx"must not override")
  ;; Trailing data after the form is an error, not silence.
  (hint-matches?
   '("(spec" "  (format-version 2)" "  (name demo)"
     "  (version \"1.0\")" "  (summary \"s\")"
     "  (source (git \"https://example.org/d.git\""
     "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
     "  (build (steps (copy \"a\" \"b\")))"
     "  (install (prefix (bin \"b\")))" "  (license mit)"
     "  (homepage \"https://example.org\"))" "42")
   #rx"trailing data")
  ;; Kind is always spec, even for hostile bytes.
  (check-pred spec-error?
              (let ([dir (write-fixture "pkg.rktd" '("(spec"))])
                (define result
                  (parameterize ([current-directory dir])
                    (with-handlers ([exn:fail:pm? (lambda (e) e)])
                      (read-spec-file "pkg.rktd")
                      'no-error)))
                (delete-directory/files dir)
                result)))

  ;; string (listof string) -> symbol, the pm kind (or 'no-error).
  ;; Second test block: Racket merges repeated (module+ test) bodies into
  ;; the one test submodule, so these see write-fixture and friends above.
(module+ test
  (define (kind-for lines)
    (define dir (write-fixture "pkg.rktd" lines))
    (define result
      (parameterize ([current-directory dir])
        (with-handlers ([exn:fail:pm? exn:fail:pm-kind])
          (read-spec-file "pkg.rktd")
          'no-error)))
    (delete-directory/files dir)
    result)

  ;; E-02: a (flag NAME) cond naming an undeclared flag is kind 'spec
  ;; with a srcloc pointing at the NAME, not the file.
  (define unknown-flag-lines
    '("(spec" "  (format-version 2)" "  (name demo)"
      "  (version \"1.0\")" "  (summary \"s\")"
      "  (source (git \"https://example.org/d.git\""
      "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
      "  (build (steps (copy \"a\" \"b\")))"
      "  (install (prefix (bin \"b\")))" "  (license mit)"
      "  (homepage \"https://example.org\")"
      "  (flags ((gui #:default #t #:doc \"Graphical interface\")))"
      "  (when (flag cli) ((version \"1.0\"))))"))
  (check-eq? (kind-for unknown-flag-lines) 'spec)
  (hint-matches? unknown-flag-lines #rx"unknown flag 'cli")
  (hint-matches? unknown-flag-lines #rx"at: pkg.rktd:[0-9]+:[0-9]+")

  ;; E-02: a second (slot ...) field is a duplicate slot, kind 'spec
  ;; with a srcloc (the generic duplicate-field check names the key).
  (define duplicate-slot-lines
    '("(spec" "  (format-version 2)" "  (name demo)"
      "  (version \"1.0\")" "  (summary \"s\")"
      "  (source (git \"https://example.org/d.git\""
      "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
      "  (build (steps (copy \"a\" \"b\")))"
      "  (install (prefix (bin \"b\")))" "  (license mit)"
      "  (homepage \"https://example.org\")"
      "  (slot lts)" "  (slot stable))"))
  (check-eq? (kind-for duplicate-slot-lines) 'spec)
  (hint-matches? duplicate-slot-lines #rx"duplicate field 'slot")
  (hint-matches? duplicate-slot-lines #rx"at: pkg.rktd:[0-9]+:[0-9]+")

  ;; E-02 positive: slot, flags and a flag cond read through; a spec
  ;; without them defaults to slot 'default and no flags.
  (define flagged-dir
    (write-fixture
     "flagged.rktd"
     '("(spec"
       "  (format-version 2)"
       "  (name demo)"
       "  (version \"1.0\")"
       "  (summary \"s\")"
       "  (source (git \"https://example.org/d.git\""
       "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
       "  (build (steps (copy \"a\" \"b\")))"
       "  (install (prefix (bin \"b\")))" "  (license mit)"
       "  (homepage \"https://example.org\")"
       "  (slot lts)"
       "  (flags ((gui #:default #t #:doc \"Graphical interface\""
       "               #:conflicts (minimal) #:requires (x11))"
       "          (minimal #:default #f #:doc \"No extras\")))"
       "  (when (flag gui) ((version \"2.0\"))))")))
  (define flagged
    (parameterize ([current-directory flagged-dir])
      (read-spec-file "flagged.rktd")))
  (check-eq? (spec-slot flagged) 'lts)
  (check-equal? (map flag-spec-name (spec-flags flagged)) '(gui minimal))
  (check-equal? (flag-spec-conflicts (car (spec-flags flagged))) '(minimal))
  (check-equal? (flag-spec-requires (car (spec-flags flagged))) '(x11))
  (check-equal? (when-spec-cond (car (spec-whens flagged))) '(flag gui))
  (delete-directory/files flagged-dir)
  (check-eq? (spec-slot minimal) 'default)
  (check-equal? (spec-flags minimal) '())
  ;; A duplicate flag name is kind 'spec on the second NAME.
  (check-eq? (kind-for
              '("(spec" "  (format-version 2)" "  (name demo)"
                "  (version \"1.0\")" "  (summary \"s\")"
                "  (source (git \"https://example.org/d.git\""
                "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))"
                "  (build (steps (copy \"a\" \"b\")))"
                "  (install (prefix (bin \"b\")))" "  (license mit)"
                "  (homepage \"https://example.org\")"
                "  (flags ((gui #:default #t #:doc \"G\")"
                "          (gui #:default #f #:doc \"G2\"))))"))
            'spec)
  ;; end of E-02 tests
  )

