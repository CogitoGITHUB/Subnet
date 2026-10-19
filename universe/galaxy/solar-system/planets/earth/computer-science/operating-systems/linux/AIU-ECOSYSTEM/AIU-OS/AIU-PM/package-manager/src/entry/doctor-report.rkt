#lang racket/base
;; doctor-report.rkt -- the health-check document for =pm doctor=:
;; what was checked, what its state is, the path it looked at, and what
;; a reader should do about it. READ-ONLY, and that is the whole point
;; (plan/FEATURE-doctor.org, plan/new-components/pm-doctor.org):
;;
;;   THIS MODULE WRITES NOTHING. It opens no output file, creates no
;;   directory, takes no lock, spawns no git, and changes nothing in
;;   the store, the profile or the vault. It does not even open a
;;   narration run: begin-run!/end-run! belong to the caller, so the
;;   only thing this module can produce is narration on the feed the
;;   caller already opened. A repair is a different verb, and a gated
;;   one.
;;
;; What it reads is the state that goes stale on its own: the profile
;; link and its generations, the store's incomplete markers, the
;; lockfile, the vault manifest, the lock record beside the vault, and
;; the vault refs the lockfile names. Every finding names the path it
;; came from, so a reader can go and look at the same thing doctor
;; looked at.
;;
;; The report is DATA (doctor-finding, below) rendered by one printer,
;; so the CLI, the MCP tool and the skill read the same document
;; (D-057: one report file per verb family). This module prints
;; nothing; narration/print-console.rkt's display-result does.
;;
;; Two decisions the design left open, taken here and named:
;;   - FEATURE-doctor.org asks "FAIL or WARN?". It is answered by the
;;     FAILING-KINDS table: each kind carries its level as data, so the
;;     exit-code decision stays with the caller and this module never
;;     has to know what an exit code means. A kind missing from that
;;     table is a bug and raises kind 'internal rather than defaulting.
;;   - The lockfile and the manifest have no home in the tree (every
;;     other command takes them as operands) and doctor takes zero
;;     operands, so their default leaves under the state root are named
;;     HERE, once, and every finding repeats the path it used. A wrong
;;     home is visible in the report, never silent.
;;
;; Areas used, all below entry/ and so legal by the one-way law:
;; errors (the refusal type), narration (the one operation path),
;; machine (scope roots, the lockfile reader), store (the marker probe
;; and the manifest), install (generations and the live link), git (the
;; namespace naming). The vault default is taken from documents.rkt
;; rather than derived a second time.

(require racket/file
         racket/list
         racket/path
         racket/string
         "../errors/error-type.rkt"
         "../narration/narration.rkt"
         "../machine/directories.rkt"
         "../store/lockfile.rkt"
         "../store/store.rkt"
         "../store/manifest.rkt"
         "../install/activate.rkt"
         "../git/vault.rkt"
         "./documents.rkt")

(provide (struct-out doctor-finding)
         profile-link-findings
         store-marker-findings
         lockfile-findings
         manifest-findings
         vault-lock-findings
         vault-clone-findings
         doctor-findings
         doctor-document
         doctor-report-text
         doctor-fail-count)

;; ---------------------------------------------------------------------------
;; The finding

;; What one check found. Four fields, in the order
;; plan/FEATURE-doctor.org fixes for the JSON document: what was
;; checked, the rule it broke, the path it looked at, and what a reader
;; should do.
(struct doctor-finding (name kind path detail) #:transparent)
;; name   : string?  the check that looked, e.g. "profile-link"
;; kind   : symbol?  the rule broken, a key of FAILING-KINDS
;; path   : string?  the path this finding is about, never null
;; detail : string?  what a reader should do about it

;; kind -> 'fail or 'warn. The FEATURE's open question, answered as
;; data so no caller re-decides it per command. A kind that is not here
;; is a bug, not a default.
(define FAILING-KINDS
  (hasheq 'profile-absent 'fail
          'profile-link-missing 'fail
          'profile-link-broken 'fail
          'profile-generation-missing 'fail
          'store-marker-stuck 'fail
          'lockfile-unreadable 'fail
          'manifest-unreadable 'fail
          'vault-absent 'fail
          'vault-clone-missing 'fail
          'lockfile-absent 'warn
          'manifest-absent 'warn
          'manifest-namespace-absent 'warn
          'vault-lock-left-behind 'warn))

;; symbol -> 'fail or 'warn, or kind 'internal naming the gap
(define (finding-level kind)
  (hash-ref FAILING-KINDS kind
            (lambda ()
              (raise-pm-error 'internal 'finding-level
                              "finding kind has no declared level"
                              #:fields `(("kind" . ,kind))
                              #:hint "every kind a check raises is listed in
                                      FAILING-KINDS before it is raised"))))

;; (listof doctor-finding) -> exact-nonnegative-integer, how many are
;; FAIL level. The caller turns that into the exit code; a report never
;; exits by itself.
(define (doctor-fail-count findings)
  (count (lambda (f) (eq? (finding-level (doctor-finding-kind f)) 'fail))
         findings))

;; ---------------------------------------------------------------------------
;; Shared helpers

;; string path string symbol -> doctor-finding, the one constructor, so
;; no check can invent a field order or skip a path of its own.
(define (found name path detail kind)
  (doctor-finding name kind (dir-text path) detail))

;; -> path, the state root every path below hangs off. It is the seam
;; apply.rkt and documents.rkt already use, so doctor names the same
;; place they do rather than adding a third convention.
(define (default-state-root)
  (build-path (roots-data (scope-roots 'user)) "aiu-pm"))

;; path -> (listof string), the immediate subdirectory names of DIR,
;; sorted, or '() when DIR is not there. Callers check for the
;; directory first; absence is an answer here, not an error.
(define (subdirectories dir)
  (sort (for/list ([p (in-list (directory-list dir))]
                   #:when (directory-exists? (build-path dir p)))
          (path->string p))
        string<?))

;; path-string string -> path, the SIBLING of FILE named NAME. The rule
;; git/vault-lock.rkt follows, named once here so doctor finds the lock
;; beside a vault by the same arithmetic its writer used.
(define (sibling-named file name)
  (define-values (base _leaf _dir?) (split-path file))
  (build-path base name))

;; ---------------------------------------------------------------------------
;; Checks. Each returns findings and never raises for a broken machine:
;; a problem is the answer, not an exception. Each narrates through
;; narration.rkt, one STEP for the category and one INFO per finding.

;; path-string -> (listof doctor-finding). The profile root, every
;; generation under it, and the one link that says which is live.
(define (profile-link-findings profile)
  (with-op 'doctor "profile" "a profile link can go stale on its own"
           #:how (dir-text profile)
           (lambda ()
             (if (not (directory-exists? profile))
                 (list (found "profile-link" profile
                              "there is no profile directory here, so no
                               generation is active for it"
                              'profile-absent))
                 (append (missing-generation-findings profile)
                         (live-link-findings profile))))))

;; profile-generations reads a missing root as empty rather than
;; raising, so an empty list here means a profile with no generations
;; yet, which is not a problem and is not reported.
(define (missing-generation-findings profile)
  (define rows (profile-generations profile))
  (step 'doctor "generations"
        "every generation under the profile root is on disk"
        #:how (dir-text profile))
  (for/list ([g (in-list rows)]
             #:when (not (directory-exists? (first g))))
    (found "profile-generation" (first g)
           "this generation is listed under the profile root but is not
            there; it was removed from under the profile"
           'profile-generation-missing)))

;; current-generation raises kind 'config when the link is absent and
;; the link resolution raises when it dangles. Both are findings here,
;; never refusals: a broken profile link is what doctor is for.
(define (live-link-findings profile)
  (define link (build-path profile "profile"))
  (cond
    [(not (link-exists? link))
     (list (found "profile-link" link
                  "no generation is active; the profile link is absent, so
                   nothing on PATH is on the caller's search path"
                  'profile-link-missing))]
    [else
     (with-handlers ([exn:fail? (lambda (e)
                                  (list (found "profile-link" link
                                               (string-append
                                                "the profile link points at a
                                                 generation that is not there ("
                                                (exn-message e) ")")
                                               'profile-link-broken)))])
       (note 'doctor (format "the live generation is ~a"
                             (dir-text (current-generation profile))))
       '())]))

;; path-string -> (listof doctor-finding). A .pm-incomplete left in a
;; versioned store directory means a materialisation died part-way.
(define (store-marker-findings state-root)
  (define store-dir (build-path state-root "store"))
  (with-op 'doctor "store" "a dead materialisation leaves its marker behind"
           #:how (dir-text store-dir)
           (lambda ()
             (if (not (directory-exists? store-dir))
                 '()
                 (begin
                   (step 'doctor "incomplete markers"
                         "a versioned directory with no marker is a finished
                          materialisation"
                         #:how (dir-text store-dir))
                   (stuck-marker-findings store-dir))))))

;; The marker only ever lives in a versioned directory, and a versioned
;; directory name is name/slot/version-hash12 (store.rkt's own layout),
;; so the walk is exactly three levels and never has to guess.
(define (stuck-marker-findings store-dir)
  (define versioned
    (for*/list ([name (in-list (subdirectories store-dir))]
                [slot (in-list (subdirectories (build-path store-dir name)))])
      (define slot-dir (build-path store-dir name slot))
      (for/list ([v (in-list (subdirectories slot-dir))])
        (build-path slot-dir v))))
  (for/list ([dir (in-list versioned)]
             #:when (store-marker-present? dir))
    (note 'doctor (format "an incomplete marker is still in ~a" dir))
    (found "store-marker" dir
           "this store directory still holds .pm-incomplete, so the run
            that was filling it never finished; remove the directory by
            hand and let the next install rebuild it"
           'store-marker-stuck)))

;; path-string -> (listof doctor-finding). A lockfile that does not
;; read leaves every install state above it unverifiable. ABSENT and
;; UNREADABLE are two kinds and two levels: FAILING-KINDS says a machine
;; with no lockfile yet is a WARN (nothing has been pinned), while a file
;; that is there and does not parse is a FAIL.
(define (lockfile-findings lockfile)
  (with-op 'doctor "lockfile" "a lock that cannot be read is not a pin"
           #:how (dir-text lockfile)
           (lambda ()
             (cond
               [(not (file-exists? lockfile))
                (list (found "lockfile" lockfile
                             "there is no lockfile here, so nothing is pinned
                              yet; every install until one is written is
                              unpinned"
                             'lockfile-absent))]
               [else
                (with-handlers ([exn:fail:pm?
                                 (lambda (e)
                                   (list (found "lockfile" lockfile
                                                (string-append
                                                 "the lockfile could not be read: "
                                                 (exn-message e))
                                                'lockfile-unreadable)))])
                  (define lf (read-lockfile lockfile))
                  (note 'doctor (format "~a pin(s) in the lockfile"
                                         (length (lockfile-entries lf))))
                  '())]))))

;; path-string -> (listof doctor-finding). The manifest is the vault's
;; inventory: does it exist, does it read, does every entry name the
;; namespace the vault is supposed to hold.
(define (manifest-findings manifest)
  (with-op 'doctor "manifest" "the manifest names what the vault holds"
           #:how (dir-text manifest)
           (lambda ()
             (cond
               [(not (file-exists? manifest))
                (list (found "manifest" manifest
                             "there is no vault manifest here, so nothing has
                              been declared into the vault"
                             'manifest-absent))]
               [else
                (with-handlers
                    ([exn:fail:pm?
                      (lambda (e)
                        (list (found "manifest" manifest
                                     (string-append
                                      "the manifest could not be read: "
                                      (exn-message e))
                                     'manifest-unreadable))))])
                  (define entries (manifest-read manifest))
                  (note 'doctor (format "~a entr(ies) in the manifest"
                                          (length entries)))
                  (for/list ([e (in-list entries)]
                             #:when (string=? (manifest-entry-namespace e) ""))
                    (found "manifest" manifest
                           (format "entry ~a names no namespace, so the vault
                                    cannot answer for it"
                                   (manifest-entry-name e))
                           'manifest-namespace-absent))]))))

;; path-string -> (listof doctor-finding). The lock record sits BESIDE
;; the vault root, and its owner record beside that. A record there
;; outliving its run is the normal reading; doctor resolves it no
;; further, because taking the lock to find out would write, which is
;; the one thing forbidden here.
(define (vault-lock-findings vault)
  (define lock (sibling-named vault "vault.lock"))
  (define owner (string->path (string-append (path->string lock) ".owner")))
  (with-op 'doctor "locks" "a lock record left beside the vault outlived its run"
           #:how (dir-text lock)
           (lambda ()
             (if (not (link-exists? lock))
                 '()
                 (begin
                   (note 'doctor (format "a lock record is present at ~a"
                                         (dir-text lock)))
                   (list (found "vault-lock" lock
                                (string-append
                                 "this lock file is present, so no other pm run
                                  can touch the vault until a human removes
                                  it"
                                 (if (link-exists? owner)
                                     (format "; its owner record is ~a"
                                             (dir-text owner))
                                     ""))
                                'vault-lock-left-behind)))))))

;; path-string path-string -> (listof doctor-finding). The agreement
;; between the lockfile and the vault: every pin the lock names needs a
;; namespace ref in the vault, or that pin cannot be fetched.
(define (vault-clone-findings vault lockfile)
  (with-op 'doctor "vault agreement"
           "a pin the vault cannot serve is not a pin"
           #:how (dir-text vault)
           (lambda ()
             (cond
               [(not (directory-exists? vault))
                (list (found "vault-clone" vault
                             "there is no vault here, so nothing can be
                              fetched and no pin can be honoured"
                             'vault-absent))]
               [else
                ;; A lockfile that does not read is the lockfile check's
                ;; finding, not this one's: it is reported once, by the
                ;; check that owns it, and doctor keeps going.
                (define entries
                  (with-handlers ([exn:fail? (lambda (_) '())])
                    (lockfile-entries (read-lockfile lockfile))))
                (step 'doctor "namespace refs"
                      "every locked package names a ref the vault holds"
                      #:how (dir-text vault))
                (for/list ([e (in-list entries)]
                           #:unless (vault-holds-ref?
                                     vault
                                     ;; a lock row names its package with a
                                     ;; symbol; the namespace naming is taken
                                     ;; on strings (D-8)
                                     (vault-namespace
                                      (symbol->string (lock-entry-name e)))))
                  (found "vault-clone" vault
                         (format "the lock pins ~a at ~a but the vault holds
                                  no ref for it"
                                 (lock-entry-name e) (lock-entry-commit e))
                         'vault-clone-missing))]))))

;; path-string string -> boolean, does the bare repo carry REF. The
;; loose ref first, then packed-refs: both are plain reads, and git is
;; never spawned, because spawning would be a subprocess and this module
;; writes nothing.
(define (vault-holds-ref? vault ref)
  (or (link-exists? (build-path vault ref))
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (regexp-match?
         (regexp (regexp-quote (string-append " " ref "$")))
         (file->string (build-path vault "packed-refs"))))))

;; ---------------------------------------------------------------------------
;; The run

;; The whole verb: it reads the state once, narrates every category,
;; and hands back DATA. It never prints, never repairs, and never
;; raises for a broken machine -- a broken machine is what it is for.
;; Every keyword defaults to the same state-root-relative place the
;; checks name, and a caller (a test, or a future CLI flag) may point
;; one elsewhere.
(define (doctor-findings
         #:state-root [state-root #f]
         #:profile [profile #f]
         #:vault [vault #f]
         #:lockfile [lockfile #f]
         #:manifest [manifest #f])
  (define root (or state-root (default-state-root)))
  (define profile-dir (or profile (build-path root "profile")))
  (define vault-dir (or vault (default-vault-dir)))
  (define lock (or lockfile (build-path root "pm.lock")))
  (define mans (or manifest (build-path root "manifest.rktd")))
  (with-op 'doctor "health check"
           "the machine's install state is asked whether it is coherent"
           #:how (dir-text root)
           (lambda ()
             (define findings
               (append (profile-link-findings profile-dir)
                       (store-marker-findings root)
                       (lockfile-findings lock)
                       (manifest-findings mans)
                       (vault-lock-findings vault-dir)
                       (vault-clone-findings vault-dir lock)))
             (for ([f (in-list findings)])
               (note 'doctor
                     (format "~a: ~a at ~a -- ~a"
                             (doctor-finding-name f)
                             (doctor-finding-kind f)
                             (doctor-finding-path f)
                             (doctor-finding-detail f))))
             (step 'doctor "finding count"
                   "every finding is counted, and the FAIL ones are the
                    findings that make the install incoherent"
                   #:how (dir-text root))
             findings)))

;; -> jsexpr, the --format json document. The key order is the one
;; plan/FEATURE-doctor.org fixes: name, format, operands, findings,
;; count, clean. Each finding is {name, kind, path, detail} in that
;; order; its level is read from FAILING-KINDS rather than duplicated
;; into the record, so a kind's level is stated once in this file.
(define (doctor-document findings
                         #:format [format "json"]
                         #:operands [operands '()])
  (hasheq 'name "doctor"
          'format format
          'operands operands
          'findings (for/list ([f (in-list findings)])
                      (hasheq 'name (doctor-finding-name f)
                              'kind (symbol->string (doctor-finding-kind f))
                              'path (doctor-finding-path f)
                              'detail (doctor-finding-detail f)))
          'count (length findings)
          'clean (and (null? findings) #t)))

;; (listof doctor-finding) -> (listof string), the text the ONE printer
;; shows. Nothing here prints; display-result does, so doctor reaches
;; the screen the way every other command does (V-3).
(define (doctor-report-text findings)
  (append
   (for/list ([f (in-list findings)])
     (format "~a: ~a -- ~a\n  at: ~a"
             (doctor-finding-name f)
             (doctor-finding-kind f)
             (doctor-finding-detail f)
             (doctor-finding-path f)))
   (list (format "~a finding(s), ~a at FAIL level; nothing was changed"
                 (length findings)
                 (doctor-fail-count findings)))))
