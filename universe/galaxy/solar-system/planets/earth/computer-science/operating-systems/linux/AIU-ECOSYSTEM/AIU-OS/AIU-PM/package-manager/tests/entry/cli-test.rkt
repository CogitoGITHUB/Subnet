#lang racket/base
;; cli-test.rkt -- the CLI suite, moved out of the module it tests
;; (step 8; step 14, done 2026-10-17, brought the rest of the inline
;; tests out the same way). It checks the promise cli.rkt keeps:
;; parsing and rendering,
;; the check runner, every --format json document, and the docs/API.org
;; goldens. The runtime path crosses three levels up from tests/entry
;; to the repo root, where docs/ sits.
;;
;; The facade is required BARE on purpose: every call below then goes
;; through its contract-out, so a wrong contract fails here, in the
;; suite, not in a consumer's tree. dispatch.rkt and documents.rkt come
;; in prefixed, and only for the three names the facade does NOT
;; re-provide (profile-entries, command-table, fetch-document); asking
;; for those unprefixed too would require the same identifier twice.

(require rackunit
         racket/file
         racket/list
         racket/runtime-path
         racket/string
         json
         "../../src/errors/error-type.rkt"
         "../../src/git/git-env.rkt"
         "../../src/store/manifest.rkt"
         "../../src/entry/cli.rkt"
         (prefix-in dispatch: "../../src/entry/dispatch.rkt")
         (prefix-in documents: "../../src/entry/documents.rkt")
         "../../src/narration/narration.rkt")

(module+ test

  ;; Parsing: empty and flags mean help; check takes one directory.
  (check-pred command-help? (parse-args #()))
  (check-pred command-help? (parse-args #("--help")))
  (check-pred command-help? (parse-args #("-h")))
  (check-equal? (command-check-dir (parse-args #("check" "specs/")))
                "specs/")
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("check"))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("frobnicate"))
                'no-error))
  ;; --format is parsed in one place, default sexp, before or after.
  (check-eq? (command-check-format (parse-args #("check" "specs/")))
             'sexp)
  (check-eq? (command-check-format
              (parse-args #("check" "specs/" "--format" "json")))
             'json)
  (check-eq? (command-check-format
              (parse-args #("--format" "json" "check" "specs/")))
             'json)
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("check" "specs/" "--format" "yaml"))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("check" "specs/" "--format"))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("--format" "sexp" "--format" "json"
                               "check" "specs/"))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("--bogus"))
                'no-error))
  (check-exn exn:fail:contract?
             (lambda () (parse-args '("check" "x"))))

  ;; Checking: a good file prints ok and exits 0.
  (define check-dir (make-temporary-directory "pm-cli~a"))
  (call-with-output-file (build-path check-dir "good.rktd")
    (lambda (port)
      (displayln "(spec (format-version 2) (name demo) (version \"1.0\")" port)
      (displayln "  (summary \"s\")" port)
      (displayln "  (source (git \"https://example.org/d.git\"" port)
      (displayln "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))" port)
      (displayln "  (build (steps (copy \"a\" \"b\")))" port)
      (displayln "  (install (prefix (bin \"b\")))" port)
      (displayln "  (license mit) (homepage \"https://example.org\"))" port)))
  (define check-out (open-output-string))
  (check-equal? (parameterize ([current-output-port check-out])
                  (run-check check-dir))
                0)
  (check-regexp-match #rx"ok: demo 1.0" (get-output-string check-out))

  ;; THE ENTRIES BUILDER. This is the one function three commands depend
  ;; on, and the list it returns is what profile-activate and
  ;; profile-remove both consume -- so it is tested against real specs,
  ;; not mocked. Two packages on purpose: one installs a single file, one
  ;; installs several, because a builder that only ever sees one shape is
  ;; not tested.
  (define entries-dir (make-temporary-directory "pm-entries~a"))
  (call-with-output-file (build-path entries-dir "one.rktd")
    (lambda (port)
      (displayln "(spec (format-version 2) (name one) (version \"1.0\")" port)
      (displayln "  (summary \"s\")" port)
      (displayln "  (source (git \"https://example.org/one.git\"" port)
      (displayln "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))" port)
      (displayln "  (build (steps (copy \"a\" \"b\")))" port)
      ;; a path the OTHER package does not claim: check-spec-conflicts
      ;; refuses two packages claiming one destination, and it is right
      ;; to. The first draft of this fixture had both claiming "b".
      (displayln "  (install (prefix (bin \"solo\")))" port)
      (displayln "  (license mit) (homepage \"https://example.org\"))" port)))
  (call-with-output-file (build-path entries-dir "many.rktd")
    (lambda (port)
      (displayln "(spec (format-version 2) (name many) (version \"2.0\")" port)
      (displayln "  (summary \"s\")" port)
      (displayln "  (source (git \"https://example.org/many.git\"" port)
      (displayln "                  \"9edb3f66fd807b096b48283debdcddccfea34bad\"))" port)
      (displayln "  (build (steps (copy \"a\" \"b\")))" port)
      (displayln "  (install (prefix (bin \"b\") (lib \"l\") (share \"s\")))" port)
      (displayln "  (license mit) (homepage \"https://example.org\"))" port)))
  (define entries-state (make-temporary-directory "pm-entries-state~a"))
  (define built
    (parameterize ([current-allow-file-urls #t])
      (dispatch:profile-entries entries-dir (path->string entries-state))))
  ;; Two entries, in resolve order, each a (name source rels) triple.
  (check-equal? (length built) 2)
  (check-equal? (map (lambda (e) (car e)) built) '("many" "one"))
  ;; The single-file package contributes exactly one relative path.
  (check-equal? (map (lambda (e) (length (caddr e))) built) '(3 1))
  ;; source is the STORE path apply writes to, so activate cannot
  ;; disagree with apply about where a package lives. Both must start
  ;; under <state>/store/ and carry name/slot/version-hash.
  (for ([e (in-list built)])
    (define src (cadr e))
    (check-true (regexp-match? (regexp-quote (string-append (path->string entries-state)
                                                          "/store/"))
                               src))
    (check-true (regexp-match? (regexp-quote (car e)) src)))
  ;; resolve order is deterministic: many before one, and the same on
  ;; every call, so a second build of the same declaration is identical.
  (check-equal? built
               (parameterize ([current-allow-file-urls #t])
                 (dispatch:profile-entries entries-dir (path->string entries-state))))

  ;; A missing declaration directory is a REFUSAL naming the path, not
  ;; a raw filesystem error. This is the case that used to escape. The
  ;; assertion is on the MESSAGE, because a refusal that does not say
  ;; what was wrong is not a refusal: a bare "not found" leaves the
  ;; reader guessing which of the two inputs was the problem.
  (define missing-specs (path->string (build-path entries-dir "nope")))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (check-pred config-error? e)
                     (check-regexp-match (regexp-quote missing-specs)
                                         (exn-message e)))]
                  ;; with-handlers takes predicate/handler PAIRS, so the
                  ;; "did not refuse at all" case needs a catch-all
                  ;; predicate rather than a bare else.
                  [(lambda (_) #t)
                   (lambda (_)
                     (check-true #f "a missing specs directory must refuse"))])
    (parameterize ([current-allow-file-urls #t])
      (dispatch:profile-entries missing-specs (path->string entries-state))))

  ;; A bad file prints its error and exits 3; others still checked.
  (call-with-output-file (build-path check-dir "bad.rktd")
    (lambda (port)
      (displayln "(spec (format-version 2) (bogus 1))" port)))
  ;; S2-03: a second bad file, and this one is not malformed -- it is a
  ;; well-formed declaration that breaks a NAMED rule (a git source that
  ;; does not pin a commit). The refusal has to carry the rule's own
  ;; name, or a user who reads "not a commit id" still does not know
  ;; which promise was broken. Nothing new prints it: the name rides out
  ;; in the error's fields, which the one error printer already shows.
  (call-with-output-file (build-path check-dir "unpinned.rktd")
    (lambda (port)
      (displayln "(spec (format-version 2) (name loose) (version \"1.0\")" port)
      (displayln "  (summary \"s\")" port)
      (displayln "  (source (git \"https://example.org/l.git\"" port)
      (displayln "                  \"main\"))" port)
      (displayln "  (build (steps (copy \"a\" \"b\")))" port)
      (displayln "  (install (prefix (bin \"b\")))" port)
      (displayln "  (license mit) (homepage \"https://example.org\"))" port)))
  (define bad-err (open-output-string))
  (define bad-out (open-output-string))
  (check-equal? (parameterize ([current-output-port bad-out]
                               [current-error-port bad-err])
                  (run-check check-dir))
                3)
  (check-regexp-match #rx"unknown key" (get-output-string bad-err))
  ;; the same refusal stream, and the name a user greps for
  (check-regexp-match #rx"rule: source-trust" (get-output-string bad-err))
  (check-regexp-match #rx"\\[source-trust\\]" (get-output-string bad-err))
  (check-regexp-match #rx"ok: demo 1.0" (get-output-string bad-out))

  ;; Missing directories fail at the boundary, kind 'config.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (run-check (build-path check-dir "no-such-dir"))
                'no-error))

  ;; Empty directories pass vacuously.
  (define empty-dir (build-path check-dir "empty"))
  (make-directory empty-dir)
  (check-equal? (run-check empty-dir) 0)

  ;; E-18a: every stage parses; one golden per command per format.
  (define (check-command pred argv sexp json)
    (define cmd (parse-args argv))
    (check-pred pred cmd)
    (check-equal? (command->sexp cmd) sexp)
    (check-equal? (command->json cmd) json))
  (check-command command-plan? #("plan" "specs/")
                 "(\"plan\" sexp (\"specs/\"))"
                 "{\"name\":\"plan\",\"format\":\"sexp\",\"operands\":[\"specs/\"]}")
  (check-command command-lock? #("lock" "pm.lock")
                 "(\"lock\" sexp (\"pm.lock\"))"
                 "{\"name\":\"lock\",\"format\":\"sexp\",\"operands\":[\"pm.lock\"]}")
  (check-command command-fetch? #("fetch" "manifest.rktd")
                 "(\"fetch\" sexp (\"manifest.rktd\"))"
                 "{\"name\":\"fetch\",\"format\":\"sexp\",\"operands\":[\"manifest.rktd\"]}")
  (check-command command-update? #("update" "vault" "pm.lock" "profile")
                 "(\"update\" sexp (\"vault\" \"pm.lock\" \"profile\"))"
                 (string-append
                  "{\"name\":\"update\",\"format\":\"sexp\","
                  "\"operands\":[\"vault\", \"pm.lock\", \"profile\"]}"))
  (check-command command-activate? #("activate" "profile" "specs" "state")
                 (string-append
                  "(\"activate\" sexp (\"profile\" \"specs\" \"state\"))")
                 (string-append
                  "{\"name\":\"activate\",\"format\":\"sexp\","
                  "\"operands\":[\"profile\", \"specs\", \"state\"]}"))
  ;; activate's own --lock rides along, and the lockfile becomes a named
  ;; operand so a reader can tell a pinned flip from an unpinned one.
  (check-command command-activate?
                 #("activate" "profile" "specs" "state" "--lock" "pm.lock")
                 (string-append
                  "(\"activate\" sexp (\"profile\" \"specs\" \"state\" \"pm.lock\"))")
                 (string-append
                  "{\"name\":\"activate\",\"format\":\"sexp\","
                  "\"operands\":[\"profile\", \"specs\", \"state\", \"pm.lock\"]}"))
  (check-command command-rollback? #("rollback" "profile" "3")
                 "(\"rollback\" sexp (\"profile\" \"3\"))"
                 "{\"name\":\"rollback\",\"format\":\"sexp\",\"operands\":[\"profile\", \"3\"]}")
  (check-command command-remove? #("remove" "profile" "pkg-a" "specs" "state")
                 (string-append
                  "(\"remove\" sexp (\"profile\" \"pkg-a\" \"specs\" \"state\"))")
                 (string-append
                  "{\"name\":\"remove\",\"format\":\"sexp\","
                  "\"operands\":[\"profile\", \"pkg-a\", \"specs\", \"state\"]}"))
  (check-command command-hold? #("hold" "profile" "pkg-a" "default")
                 "(\"hold\" sexp (\"profile\" \"pkg-a\" \"default\"))"
                 (string-append "{\"name\":\"hold\",\"format\":\"sexp\","
                                "\"operands\":[\"profile\", \"pkg-a\", \"default\"]}"))
  ;; D-026: why names the lock and the manifest it read, so the answer
  ;; can be reproduced later. Three operands, not one.
  (check-command command-why? #("why" "pm.lock" "pm.manifest" "pkg-a")
                 "(\"why\" sexp (\"pm.lock\" \"pm.manifest\" \"pkg-a\"))"
                 (string-append
                  "{\"name\":\"why\",\"format\":\"sexp\","
                  "\"operands\":[\"pm.lock\", \"pm.manifest\", \"pkg-a\"]}"))
  (check-command command-owner? #("owner" "profile" "bin/prog")
                 "(\"owner\" sexp (\"profile\" \"bin/prog\"))"
                 "{\"name\":\"owner\",\"format\":\"sexp\",\"operands\":[\"profile\", \"bin/prog\"]}")
  (check-command command-verify? #("verify" "vault" "pm.lock" "pkg-a")
                 "(\"verify\" sexp (\"vault\" \"pm.lock\" \"pkg-a\"))"
                 (string-append
                  "{\"name\":\"verify\",\"format\":\"sexp\","
                  "\"operands\":[\"vault\", \"pm.lock\", \"pkg-a\"]}"))
  (check-command command-help? #()
                 "(\"help\" sexp ())"
                 "{\"name\":\"help\",\"format\":\"sexp\",\"operands\":[]}")
  ;; --format rides along on the new commands too.
  (check-command command-why?
                 #("why" "pm.lock" "pm.manifest" "pkg-a" "--format" "json")
                 "(\"why\" json (\"pm.lock\" \"pm.manifest\" \"pkg-a\"))"
                 (string-append
                  "{\"name\":\"why\",\"format\":\"json\","
                  "\"operands\":[\"pm.lock\", \"pm.manifest\", \"pkg-a\"]}"))
  ;; apply's own flags: the gate parses, the datum carries it, and the
  ;; bare form is the un-confirmed one. D-040.
  (check-command command-apply? #("apply" "specs")
                 "(\"apply\" sexp (\"specs\" \"no\"))"
                 "{\"name\":\"apply\",\"format\":\"sexp\",\"operands\":[\"specs\", \"no\"]}")
  (check-command command-apply?
                 #("apply" "specs" "--lock" "pm.lock" "--confirm")
                 "(\"apply\" sexp (\"specs\" \"pm.lock\" \"yes\"))"
                 (string-append
                  "{\"name\":\"apply\",\"format\":\"sexp\","
                  "\"operands\":[\"specs\", \"pm.lock\", \"yes\"]}"))
  ;; Wrong arity refuses; unknown commands exit 78 (EX_CONFIG, D-045).
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("plan"))
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (parse-args #("hold" "profile" "pkg-a"))
                'no-error))
  (check-equal? (pm-error-exit-code
                 (with-handlers ([exn:fail:pm? (lambda (e) e)])
                   (parse-args #("frobnicate"))
                   'no-error))
                78)

  ;; ---------------------------------------------------------------
  ;; docs/API.org is the golden (E-26). Every "** =pm ...=" header is
  ;; re-parsed and re-rendered here, so a documented example that
  ;; drifts from the real --format json output fails the gate.
  (define-runtime-path test-dir ".")
  (define api-path
    (simplify-path (build-path test-dir 'up 'up 'up "docs" "API.org")))
  (check-true (file-exists? api-path) "docs/API.org must exist")
  (define api-lines (file->string api-path))
  (define (api-examples text)
    ;; -> (listof (list command-line json-string)), in document order.
    (let loop ([ls (string-split text "\n")] [acc '()])
      (cond
        [(null? ls) (reverse acc)]
        [(regexp-match #rx"^\\*\\* =pm (.+)=\\s*$" (car ls))
         => (lambda (m)
              (define line (cadr m))
              (define rest (cdr ls))
              (define next (and (pair? rest) (car rest)))
              (cond
                ;; string-prefix? here is racket/base's PATTERN form:
                ;; (string-prefix? STRING PATTERN), not the string one.
                [(and next (string-prefix? next ": "))
                 (loop (cdr rest)
                       (cons (list line (substring next 2)) acc))]
                [else (loop rest acc)]))]
        [else (loop (cdr ls) acc)])))
  (define examples (api-examples api-lines))
  ;; Sixteen commands plus --help. Two are documented twice -- apply as
  ;; the bare form and the confirmed form, activate with and without
  ;; --lock -- because both variants are real invocations and a reader
  ;; needs to see the gate spelled out. Every example here is parsed and
  ;; checked against the real parser (docs/API.org is a test, not prose).
  (check-equal? (length examples) 19)
  (check-equal? (sort (remove-duplicates
                       (map (lambda (e)
                              (let ([words (string-split (car e) " ")])
                                (define w (if (string=? (car words) "pm")
                                              (cadr words)
                                              (car words)))
                                ;; "pm --help" documents the help command.
                                (if (string=? w "--help") "help" w)))
                            examples))
                     string<?)
               (sort (append (map car dispatch:command-table)
                             (list "check" "help"))
                     string<?))
  (for ([ex (in-list examples)])
    (define words (string-split (car ex) " "))
    (define argv
      (list->vector
       (if (and (pair? words) (string=? (car words) "pm"))
           (cdr words)
           words)))
    (check-equal? (command->json (parse-args argv))
                  (cadr ex)
                  (string-append "docs/API.org is stale for: " (car ex))))

  ;; fetch dispatch shapes results without touching real state: a dead
  ;; URL reports failed in a temp vault, and the JSON carries it.
  (define fetch-manifest (build-path check-dir "fetch.rktd"))
  (manifest-write fetch-manifest
                  (list (manifest-entry "nope" "file:///nonexistent-pm-cli"
                                        "refs/vault/nope" 1 #f '() #f)))
  (define fetch-vault (build-path check-dir "vault.git"))
  (define fetch-doc
    (parameterize ([current-allow-file-urls #t]
                   [verbose-screen? #f])
      (documents:fetch-document (path->string fetch-manifest)
                      #:vault (path->string fetch-vault))))
  (check-equal? (length fetch-doc) 1)
  (check-equal? (hash-ref (car fetch-doc) 'name) "nope")
  (check-equal? (hash-ref (car fetch-doc) 'status) "failed")
  (check-true (string? (hash-ref (car fetch-doc) 'detail)))
  (delete-directory/files check-dir))
