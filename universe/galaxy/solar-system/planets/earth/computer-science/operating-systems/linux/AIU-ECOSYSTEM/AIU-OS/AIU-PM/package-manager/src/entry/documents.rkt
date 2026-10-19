#lang racket/base
;; documents.rkt -- every command result as plain data and as text
;; (E-26). The envelope is name/format/operands; a command that
;; produces something adds result keys, and key order in write-json
;; follows hash insertion order, so the tests and the examples in
;; docs/API.org agree on it. display-help prints the usage text once,
;; through display-result (V-3: no command in the tree prints by
;; itself). Builders only: nothing here parses, dispatches or spawns.

(require racket/file
         racket/list
         racket/port
         racket/string
         json
         "../errors/error-type.rkt"
         "../spec/spec.rkt"
         "../spec/spec-read.rkt"
         "../spec/plan.rkt"
         "../store/lockfile.rkt"
         "../store/query.rkt"
         "../store/update.rkt"
         "../store/manifest.rkt"
         "../install/apply.rkt"
         "../install/activate.rkt"
         "../machine/directories.rkt"
         "../narration/narration.rkt"
         "../narration/print-console.rkt"
         "../spec/version.rkt")

(provide display-help
         require-dir
         dir-text
         sorted-rktd-files
         plan-document
         check-ok-lines
         status-document
         held-document
         default-vault-dir
         fetch-document
         outdated-document
         lock-document
         why-document
         owner-document
         generations-document
         verify-pin
         verify-document
         rollback-generation
         generation-document
         activate-document
         json-text
         apply-document
         apply-preview)

;; -> void, prints usage to stdout
(define (display-help)
  ;; V-3: the usage text is printed ONCE, through display-result, so
  ;; no command in the tree prints by itself.
  (display-result
   (list
    "usage: pm [--format sexp|json] COMMAND [ARGS] | pm --help"
    ""
    "  check DIR          validate every .rktd file, print ok lines"
    "  plan SPECDIR       show the install plan (not executable yet)"
    "  lock LOCKFILE      show what the lockfile pins"
    "  fetch MANIFEST     fetch all declared packages into the vault"
    "  apply SPECDIR      show the apply plan; changes NOTHING"
     "  apply SPECDIR --lock LOCK --confirm   apply it (the gate)"
    "  update STATEDIR    check all packages (not executable yet)"
    "  rollback PROFILE N   repoint the profile at generation N"
    "  activate PROF SPECS STATE  build a generation and flip [--lock F]"
    "  remove PROF PKG SPECS STATE  build a generation minus one package"
    "  hold PROFILE PKG SLOT pin a slot (not executable yet)"
    "  why LOCK MAN PKG   why this package is declared"
    "  owner PROFILE REL  who claims a relative path"
    "  update VAULT LOCK PROFILE   check every locked package"
    "  hold PROFILE PKG SLOT  pin a slot against updates"
    "  verify VAULT LOCK PKG  re-check a package against its pin"
    "  verify NAME        re-check a tree (not executable yet)"
    "  status PROFILE LOCKFILE what is installed, with held marks"
    "  held PROFILE       what is held"
    "  outdated VAULT LOCKFILE PROFILE what is behind, from the vault"
    "  --format           output shape, sexp (default) or json"
   )))

;; path-string path -> boolean, regular file ending .rktd
(define (rktd-file? dir p)
  (define full (build-path dir p))
  (and (file-exists? full)
       (string-suffix? (path->string p) ".rktd")))

;; path-string -> (listof path), sorted .rktd files directly inside
(define (sorted-rktd-files dir)
  (map string->path
       (sort (for/list ([p (in-list (directory-list dir))]
                        #:when (rktd-file? dir p))
               (path->string (build-path dir p)))
             string<?)))

;; ---------------------------------------------------------------------------
;; Result documents (E-26). The envelope is name/format/operands; a
;; command that produces something adds result keys. Key order in
;; write-json follows hash insertion order, so the tests and the
;; examples in docs/API.org agree on it.

;; path-string -> void, kind 'config when the directory is missing
(define (require-dir dir)
  (unless (directory-exists? dir)
    (raise-pm-error 'config 'pm "directory not found"
                    #:fields `(("dir" . ,dir)))))

;; any -> string, a directory as text for an event. The CLI hands these
;; functions strings (they come from argv) and the tests hand them
;; paths, so both shapes must narrate.
(define (dir-text d)
  (if (path? d) (path->string d) (format "~a" d)))

;; path-string -> jsexpr (listof jsexpr), one object per .rktd in DIR,
;; in file order. Reads every spec, so a bad spec raises here exactly
;; as it does in run-check. No resolution, no ordering: the plan as
;; written. Keys inside a package are alphabetical, which is what
;; write-json does to an immutable hash; the envelope order is ours.
(define (plan-document dir)
  (require-dir dir)
  (with-op 'plan (dir-text dir) "an install plan was requested"
           #:how "read every .rktd in the directory"
           (lambda ()
             ;; G-01: collisions fail here, at plan time, with both
             ;; names in the message -- never half-installed later.
             (define specs
               (for/list ([f (in-list (sorted-rktd-files dir))])
                 (read-spec-file f)))
             (step 'plan "conflicts"
                   "no two packages may claim one destination")
             (check-spec-conflicts specs)
             (for/list ([f (in-list (sorted-rktd-files dir))]
                        [s (in-list specs)])
               (step 'plan
                     (string-append (symbol->string (spec-name s))
                                    " "
                                    (version->string (spec-version s)))
                     "every spec in the directory enters the plan"
                     #:how (path->string f))
               (hasheq 'name (symbol->string (spec-name s))
                       'version (version->string (spec-version s))
                       'deps (for/list ([d (in-list (spec-deps s))])
                               (hasheq 'name (symbol->string (dep-name d))
                                       'version (version->string
                                                 (dep-version d)))))))))

;; path-string -> (listof string), the ok lines of a check run
(define (check-ok-lines dir)
  (require-dir dir)
  (with-op 'check (dir-text dir) "every .rktd in the directory was validated"
           #:how "read each spec; a bad one raises kind 'spec"
           (lambda ()
             (for/list ([f (in-list (sorted-rktd-files dir))])
               (define s (read-spec-file f))
               (step 'check
                     (string-append (symbol->string (spec-name s))
                                    " "
                                    (version->string (spec-version s)))
                     "the spec parsed and passed every field check"
                     #:how (path->string f))
               (format "ok: ~a ~a"
                       (spec-name s)
                       (version->string (spec-version s)))))))

;; path-string path-string -> jsexpr, one object per installed
;; package, in name order. Reads the lock for versions and slots; the
;; ledger underneath answers what is really there.
(define (status-document profile lockfile)
  (define locks (lockfile-entries (read-lockfile lockfile)))
  (define rows (query-status profile locks))
  (for/list ([r (in-list rows)])
    (hasheq 'name (first r)
            'version (second r)
            'slot (third r)
            'held (if (fourth r) #t #f)
            'rels (fifth r))))

;; path-string -> jsexpr, the holds as pairs
(define (held-document profile)
  (define holds (query-held profile))
  (for/list ([h (in-list holds)])
    (hasheq 'name (first h) 'slot (second h))))

;; -> path, the vault pm commands use when none is given: the vault
;; inside the user state root. One default, documented here, so every
;; command finds the same vault without being told.
(define (default-vault-dir)
  (build-path (roots-data (scope-roots 'user)) "aiu-pm" "vault" "vault.git"))

;; path-string -> jsexpr, one object per fetched package, manifest order.
;; pm-fetch already narrates each package and the summary is
;; deterministic, so this only shapes the document. The vault defaults
;; to the shared one; tests pass a temp dir so the real state is never
;; touched.
(define (fetch-document manifest #:vault [vault #f])
  (define vroot (if vault
                    (if (path? vault) (path->string vault) vault)
                    (path->string (default-vault-dir))))
  (define results (pm-fetch vroot manifest))
  (for/list ([r (in-list results)])
    (hasheq 'name (first r)
            'status (symbol->string (second r))
            'detail (third r))))

;; path-string path-string path-string -> (listof string), one info line
;; per locked package, input order kept. Outdated is answered by the
;; vault, not by the lock alone.
(define (outdated-document vault lockfile profile)
  (define locks (lockfile-entries (read-lockfile lockfile)))
  (update-report (update-all vault locks '() profile)))

;; path-string -> jsexpr, the lockfile as it stands. `lock` is a READ:
;; it reports what is locked, it never rewrites the lock behind the
;; user's back. Writing a lock is apply's job, and apply derives one.
(define (lock-document lockfile)
  (hasheq 'path lockfile
          'entries (for/list ([e (in-list (lockfile-entries
                                          (read-lockfile lockfile)))])
                     (hasheq 'name (lock-entry-name e)
                             'version (lock-entry-version e)
                             'commit (lock-entry-commit e)
                             'url (lock-entry-url e)
                             'slot (lock-entry-slot e)
                             'flags (lock-entry-flags e)
                             'deps (lock-entry-deps e)))))

;; path-string path-string string -> jsexpr, why this package is in the
;; declaration at all. The answer is provenance, so the inputs are
;; named in the result: a reader can see which lock and which manifest
;; were consulted, or the answer cannot be checked later.
(define (why-document lockfile manifest name)
  (define locks (lockfile-entries (read-lockfile lockfile)))
  (define mans (manifest-read manifest))
  (define w (query-why locks mans name))
  (hasheq 'name name
          'lock lockfile
          'manifest manifest
          'verdict (first w)
          'declared-by (second w)
          'version (third w)
          'files (fourth w)
          'run (fifth w)
          'why (sixth w)))

;; path-string string -> jsexpr, who owns a relative path in the profile.
;; A path nobody claims is a real answer, not an empty result: `owner`
;; and `target` are both null, and that is worth printing plainly.
(define (owner-document profile target)
  (define c (query-owner profile target))
  (if c
      (hasheq 'path target 'owner (car c) 'target (cadr c))
      (hasheq 'path target 'owner #f 'target #f)))

;; ---------------------------------------------------------------------------
;; Documents for the commands that read state. Each one names its inputs
;; in the result, so an answer cannot be repeated against different
;; inputs later and still look like the same answer.

;; path-string -> jsexpr, the generations of a profile, oldest first,
;; each with its provenance or an explicit null. A generation whose
;; provenance predates provenance recording says so rather than
;; pretending it was never recorded.
(define (generations-document profile)
  (for/list ([g (in-list (profile-generations profile))])
    (define dir (first g))
    (define prov (second g))
    (hasheq 'path (path->string dir)
            'run (if prov (car prov) #f)
            'interface (if prov (cadr prov) #f)
            'specs (if prov (caddr prov) #f))))

;; path-string -> jsexpr, one lock entry, or a refusal. verify needs
;; the pin to have come from somewhere; taking it from the lock is what
;; makes the check meaningful rather than decorative.
(define (verify-pin lockfile name)
  (for/or ([e (in-list (lockfile-entries (read-lockfile lockfile)))])
    (and (string=? (lock-entry-name e) name) (lock-entry-commit e))))

;; path-string path-string string -> jsexpr, the verify verdict.
(define (verify-document vault lockfile name)
  (define pin (verify-pin lockfile name))
  (unless pin
    (raise-pm-error 'config 'pm "no such package in the lockfile"
                    #:fields `(("name" . ,name) ("lockfile" . ,lockfile))))
  (define v (query-verify vault "" name pin))
  (hasheq 'name name 'pin pin
          'verdict (first v) 'ok (second v) 'detail (third v)))


;; ---------------------------------------------------------------------------
;; Documents for the three profile commands.
;;
;; Each returns the generation the profile points at AFTER the change, so
;; a caller can see where it landed, not merely that it moved. That is
;; the same rule the rest of the surface follows: report the result, not
;; the fact of a result.

;; string? string? -> path, generation N of a profile. The number arrives
;; as a string from the command line, so it is parsed and checked HERE:
;; profile-rollback's contract demands an exact integer, and a bad number
;; must be a refusal naming the argument, never a contract violation from
;; deep inside the engine.
(define (rollback-generation profile n)
  (define parsed (string->number n))
  (unless (and parsed (exact-integer? parsed) (>= parsed 0))
    (raise-pm-error 'config 'pm "generation must be a non-negative whole number"
                    #:fields `(("generation" . ,n))
                    #:hint "pm rollback <profile> <n>, where n is 0, 1, 2, ..."))
  (profile-rollback profile parsed))

;; string? path? -> jsexpr, the generation a flip landed on.
(define (generation-document path)
  (hasheq 'generation (path->string path)))

;; string? string? string? (or/c string? #f) -> jsexpr, the new generation
;; after activate, with its provenance. The lockfile travels back in the
;; result when one was named, so a reader can tell a pinned flip from an
;; unpinned one without re-reading the command line.
(define (activate-document specs state lock gen)
  (hasheq 'generation (path->string gen)
          'specs specs
          'state state
          'lock (or lock #f)))

;; jsexpr -> string, write-json prints to the current port and returns
;; void; here the value is spliced into a bigger document.
(define (json-text j)
  (with-output-to-string (lambda () (write-json j))))


;; ---------------------------------------------------------------------------
;; pm apply (D-040)
;;
;; The whole human gate lives here and nowhere else. Without --confirm
;; we derive the plan, print it, and change NOTHING, exiting 0: a
;; preview is not a lesser success, it is the ordinary answer to "what
;; would this do". With --confirm the same pm-apply performs it. Both
;; paths call the SAME pm-apply, so the plan that is shown and the plan
;; that is run cannot drift apart.
;;
;; The JSON document carries `confirmed` and `applied` explicitly, so a
;; machine reader can never mistake a preview for a change.

;; string? (or/c string? #f) -> (listof (list string symbol? (listof string?)))
;; One row per package: name, outcome, and the actions it takes. The
;; dry derivation is the single source of the plan for both paths.
(define (apply-document specs lock)
  (for/list ([row (in-list (pm-apply-dry specs #:lock lock))])
    (list (car row) (cadr row) (caddr row))))

;; string? (listof rows) -> list, the text preview. It says plainly that
;; nothing changed; an empty plan printed with no such line would be
;; the worst possible reading of nothing happening.
(define (apply-preview specs rows)
  (list (string-append
         (format "~a package(s) planned from ~a, nothing changed"
                 (length rows) specs)
         "\n"
         (string-join
          (for/list ([r (in-list rows)])
            (format "  ~a ~a~a"
                    (car r) (cadr r)
                    (if (null? (caddr r))
                        ""
                        (format " (~a action(s))" (length (caddr r))))))
          "\n")
         "re-run with --confirm to apply this plan")))

