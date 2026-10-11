#lang racket/base
;; plan.rkt -- immutable action structs plus plan text. Pure, no I/O.
;; Full spec-to-plan derivation waits for the resolve phase; this module
;; holds the data model, the plan container and the stable renderer that
;; dry-run prints and golden tests compare (A-3).

(require racket/contract/base
         racket/string
         racket/port
         openssl/sha1
         "errors.rkt"
         "git-id.rkt"
         "spec.rkt"
         "version.rkt"
         "flags.rkt"
         "resolve.rkt")

(provide
 (struct-out fetch-action)
 (struct-out verify-action)
 (struct-out extract-action)
 (struct-out run-step-action)
 (struct-out install-file-action)
 (struct-out write-file-action)
 (struct-out symlink-action)
 (struct-out remove-path-action)
 (struct-out plan)
 (struct-out package-plan)
 (contract-out
  ;; any -> boolean, one of the eight action kinds below
  [action? (-> any/c boolean?)]
  ;; plan -> string, one line per action in order, stable for goldens
  [plan->text (-> plan? string?)]
  ;; (listof action) -> plan
  [list->plan (-> (listof action?) plan?)]
  ;; package-plan -> string, stable multi-line rendering for goldens
  [package-plan->text (-> package-plan? string?)]
  ;; spec (listof cons) (listof string) -> package-plan, one package
  [derive-package-plan
   (-> spec? (listof (cons/c symbol? boolean?)) (listof string?)
       package-plan?)]
  ;; (listof spec) (listof cons) (listof cons) -> (listof package-plan),
  ;; deps-first order; cycles and missing providers raise kind 'resolve
  ;; through resolve.rkt, flag problems kind 'config through flags.rkt
  [derive-plans
   (-> (listof spec?) (listof (cons/c symbol? boolean?))
       (listof (cons/c symbol? boolean?)) (listof package-plan?))]
  ;; package-plan -> string, store path below <state>/store (D-023):
  ;; name/slot/version-hash12; two slots plan to two dirs
  [package-plan-store-dir (-> package-plan? string?)]))

;; ---------------------------------------------------------------------------
;; Guard helper

;; string any -> void, fields must be strings (backend converts at edge)
(define (check-string-fields who pairs)
  (for ([p (in-list pairs)])
    (unless (string? (cdr p))
      (raise-pm-error 'internal who "action field must be a string"
                      #:fields `(("field" . ,(car p))
                                 ("value" . ,(cdr p)))))))

;; ---------------------------------------------------------------------------
;; Actions (A-3: data first, effects at the edge; paths stay strings here
;; so plans print and diff stably; the local backend converts at its edge)

(struct fetch-action (url commit dest)
  #:transparent
  #:guard (lambda (url commit dest _n)
            (check-string-fields 'fetch-action
                                 `(("url" . ,url) ("commit" . ,commit)
                                   ("dest" . ,dest)))
            (values url commit dest)))
;; url commit dest : string?  what to fetch, exact pin, where to stage it

(struct verify-action (path expected-hash algorithm)
  #:transparent
  #:guard (lambda (path expected-hash algorithm _n)
            (check-string-fields 'verify-action
                                 `(("path" . ,path)
                                   ("expected-hash" . ,expected-hash)
                                   ("algorithm" . ,algorithm)))
            (values path expected-hash algorithm)))
;; path expected-hash algorithm : string?  integrity check before use

(struct extract-action (src dest)
  #:transparent
  #:guard (lambda (src dest _n)
            (check-string-fields 'extract-action
                                 `(("src" . ,src) ("dest" . ,dest)))
            (values src dest)))
;; src dest : string?  export a tree from the vault mirror at its pin

(struct run-step-action (name argv cwd)
  #:transparent
  #:guard (lambda (name argv cwd _n)
            (check-string-fields 'run-step-action
                                 `(("name" . ,name) ("cwd" . ,cwd)))
            (unless (and (list? argv) (andmap string? argv)
                         (pair? argv))
              (raise-pm-error 'internal 'run-step-action
                              "argv must be a nonempty string list"
                              #:fields `(("value" . ,argv))))
            (values name argv cwd)))
;; name cwd : string?  step label and working directory for E-8 output
;; argv : (nonempty-listof string?)  exact command, never a shell string

(struct install-file-action (src dest mode)
  #:transparent
  #:guard (lambda (src dest mode _n)
            (check-string-fields 'install-file-action
                                 `(("src" . ,src) ("dest" . ,dest)))
            (unless (and (exact-integer? mode) (<= 0 mode #o777))
              (raise-pm-error 'internal 'install-file-action
                              "mode must be an octal permission"
                              #:fields `(("value" . ,mode))))
            (values src dest mode)))
;; src dest : string?  staged file to its versioned home
;; mode : (integer-in 0 511)  permission bits, preserved from export

(struct write-file-action (path content)
  #:transparent
  #:guard (lambda (path content _n)
            (check-string-fields 'write-file-action
                                 `(("path" . ,path)
                                   ("content" . ,content)))
            (values path content)))
;; path content : string?  generated files (autoloads, stamps, manifests)

(struct symlink-action (target link)
  #:transparent
  #:guard (lambda (target link _n)
            (check-string-fields 'symlink-action
                                 `(("target" . ,target) ("link" . ,link)))
            (values target link)))
;; target link : string?  the `current` link flip is one of these

(struct remove-path-action (path)
  #:transparent
  #:guard (lambda (path _n)
            (check-string-fields 'remove-path-action `(("path" . ,path)))
            (values path)))
;; path : string?  cleanup of staging on failure, explicit and logged

;; any -> boolean, one of the eight action kinds
(define (action? v)
  (or (fetch-action? v) (verify-action? v) (extract-action? v)
      (run-step-action? v) (install-file-action? v)
      (write-file-action? v) (symlink-action? v)
      (remove-path-action? v)))

(struct plan (actions)
  #:transparent
  #:guard (lambda (actions _n)
            (unless (and (list? actions) (andmap action? actions))
              (raise-pm-error 'internal 'plan
                              "plan holds action structs only"
                              #:fields `(("value" . ,actions))))
            (values actions)))
;; actions : (listof action?)  ordered, interpreted top to bottom

;; (listof action) -> plan
(define (list->plan actions)
  (plan actions))

;; ---------------------------------------------------------------------------
;; Package plans (E-04: spec + resolved flags + dep identities -> data)

;; A package plan is pure data: everything lowering (E-06) and the lock
;; (E-05) need, decided here and nowhere else. Manifest pins and vault
;; state are inputs of later stages, not of derivation: dep identities
;; are name + exact version (D-007), so no vault read is needed to plan.
(struct package-plan
  (name slot version commit flags deps steps install check input-hash)
  #:transparent
  #:guard (lambda (name slot version commit flags deps steps
                        install check input-hash _n)
            (unless (package-name? name)
              (raise-pm-error 'spec 'package-plan "bad package name"
                              #:fields `(("value" . ,name))))
            (unless (slot-name? slot)
              (raise-pm-error 'spec 'package-plan "bad slot name"
                              #:fields `(("value" . ,slot))))
            (unless (version? version)
              (raise-pm-error 'spec 'package-plan "not a version"
                              #:fields `(("value" . ,version))))
            (unless (git-id? commit)
              (raise-pm-error 'spec 'package-plan "not a commit id"
                              #:fields `(("value" . ,commit))))
            (unless (and (list? flags)
                         (andmap (lambda (p)
                                   (and (pair? p)
                                        (symbol? (car p))
                                        (boolean? (cdr p))))
                                 flags))
              (raise-pm-error 'spec 'package-plan "flags must be name.value"
                              #:fields `(("value" . ,flags))))
            (unless (and (list? deps) (andmap string? deps))
              (raise-pm-error 'spec 'package-plan "deps must be strings"
                              #:fields `(("value" . ,deps))))
            (unless (and (list? steps) (andmap build-step? steps))
              (raise-pm-error 'spec 'package-plan "steps must be build steps"
                              #:fields `(("value" . ,steps))))
            (unless (install-spec? install)
              (raise-pm-error 'spec 'package-plan "not an install spec"
                              #:fields `(("value" . ,install))))
            (unless (or (not check) (list? check))
              (raise-pm-error 'spec 'package-plan "check must be a form or #f"
                              #:fields `(("value" . ,check))))
            (unless (and (string? input-hash) (> (string-length input-hash) 0))
              (raise-pm-error 'spec 'package-plan "input hash must be nonempty"
                              #:fields `(("value" . ,input-hash))))
            (values name slot version commit flags deps steps
                    install check input-hash)))
;; name       : package-name?  D-8
;; slot       : slot-name?     version stream (D-023)
;; version    : version?       exact matching only (D-007)
;; commit     : string?        full commit id from the spec source
;; flags      : (listof (cons symbol boolean))  resolved, full coverage
;; deps       : (listof string?)  "name version" identities, sorted
;; steps      : (listof build-step?)  from the spec build
;; install    : install-spec?  from the spec install
;; check      : (or/c list? #f)  the single check form, or #f when absent
;; input-hash : string?  sha1 hex over the canonical rendering below

;; ---------------------------------------------------------------------------
;; Derivation (spec + resolved flags + dep identities -> package-plan)

;; string -> string, sha1 hex of the full content (stable across runs:
;; sha1 over bytes, never equal-hash-code, which a runtime may salt)
(define (string-sha1hex s)
  (bytes->hex-string
   (sha1-bytes (open-input-string s))))

;; package-plan -> string, the canonical bytes the input hash covers.
;; One fact per line, fields in struct order, flags in declared order,
;; dep identities sorted: two derivations of the same inputs hash equal.
(define (package-plan-canonical pp)
  (string-join
   (append
    (list (format "name ~a" (package-plan-name pp))
          (format "slot ~a" (package-plan-slot pp))
          (format "version ~a"
                  (version->string (package-plan-version pp)))
          (format "commit ~a" (package-plan-commit pp)))
    (for/list ([f (in-list (package-plan-flags pp))])
      (format "flag ~a=~a" (car f) (cdr f)))
    (for/list ([d (in-list (package-plan-deps pp))])
      (format "dep ~a" d))
    (for/list ([s (in-list (package-plan-steps pp))])
      (format "step ~a ~a"
              (build-step-name s)
              (string-join (map (lambda (a) (format "~s" a))
                                 (build-step-args s))
                           " ")))
    (list (format "install ~s" (install-spec-forms
                                (package-plan-install pp)))
          (format "check ~s" (package-plan-check pp))))
   "\n"))

;; spec (listof cons) (listof string) -> package-plan, one package.
;; The flags must cover exactly the declared names (a resolution from
;; another spec is caller error, kind 'config); dep identities arrive
;; sorted "name version" strings from the caller.
(define (derive-package-plan specification resolved dep-identities)
  (define declared-names (map flag-spec-name (spec-flags specification)))
  (define given-names (map car resolved))
  (unless (and (= (length declared-names) (length given-names))
               (andmap (lambda (n) (memq n declared-names)) given-names))
    (raise-pm-error 'config 'derive-package-plan
                    "flags do not match declared"
                    #:fields `(("spec" . ,(format "~a"
                                                 (spec-name specification))))))
  (define forms (install-spec-forms (spec-install specification)))
  (define check-form
    (let ((found (filter (lambda (form)
                           (and (pair? form) (eq? (car form) 'check)))
                         forms)))
      (if (null? found) #f (car found))))
  (define proto
    (package-plan (spec-name specification)
                  (spec-slot specification)
                  (spec-version specification)
                  (source-commit (spec-source specification))
                  resolved
                  (sort dep-identities string<?)
                  (spec-build specification)
                  (spec-install specification)
                  check-form
                  "pending"))
  (struct-copy package-plan proto
               [input-hash (string-sha1hex
                            (package-plan-canonical proto))]))

;; (listof spec) (listof cons) (listof cons) -> (listof package-plan),
;; deps-first order via resolve.rkt: missing providers and cycles raise
;; kind 'resolve there; flag problems raise kind 'config in flags.rkt.
(define (derive-plans specifications global-config per-package-config)
  (define ordered (resolve specifications specifications))
  (for/list ([s (in-list ordered)])
    (derive-package-plan
     s
     (resolve-flags s global-config per-package-config)
     (for/list ([d (in-list (spec-deps s))])
       (format "~a ~a"
               (dep-name d)
               (version->string (dep-version d)))))))

;; package-plan -> string, store path below <state>/store (D-023)
(define (package-plan-store-dir pp)
  (string-append (symbol->string (package-plan-name pp))
                 "/"
                 (symbol->string (package-plan-slot pp))
                 "/"
                 (version->string (package-plan-version pp))
                 "-"
                 (substring (package-plan-input-hash pp) 0 12)))

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

;; ---------------------------------------------------------------------------
;; Rendering (stable text for dry-run output and golden files)

;; action -> string, one line
(define (action->line a)
  (cond [(fetch-action? a)
         (format "fetch ~a @ ~a -> ~a"
                 (fetch-action-url a)
                 (fetch-action-commit a)
                 (fetch-action-dest a))]
        [(verify-action? a)
         (format "verify ~a ~a:~a"
                 (verify-action-path a)
                 (verify-action-algorithm a)
                 (verify-action-expected-hash a))]
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
        [else (raise-pm-error 'internal 'action->line "not an action"
                              #:fields `(("value" . ,a)))]))

;; plan -> string, one line per action in order, stable for goldens
(define (plan->text p)
  (string-join (map action->line (plan-actions p)) "\n"))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           "errors.rkt"
           "spec.rkt"
           "version.rkt")

  ;; Every action builds and predicates sort them.
  (define fetch-1
    (fetch-action "https://example.org/r.git" (make-string 40 #\a) "/tmp/s"))
  (check-true (action? fetch-1))
  (check-false (action? "fetch"))
  (check-false (action? 42))

  ;; Guards reject with kind 'internal (programmer-side construction).
  (define (internal-kind thunk)
    (with-handlers ([exn:fail:pm? exn:fail:pm-kind])
      (thunk)
      #f))
  (check-eq? (internal-kind (lambda () (fetch-action 42 "c" "d")))
             'internal)
  (check-eq? (internal-kind
              (lambda () (run-step-action "n" '() "d")))
             'internal)
  (check-eq? (internal-kind
              (lambda () (run-step-action "n" "not-a-list" "d")))
             'internal)
  (check-eq? (internal-kind
              (lambda () (install-file-action "s" "d" #o1000)))
             'internal)
  (check-eq? (internal-kind (lambda () (plan '(1 2 3)))) 'internal)
  (check-pred internal-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (plan '(oops))))

  ;; Golden: a hand-built plan renders to stable text.
  (define golden-plan
    (list->plan
     (list fetch-1
           (verify-action "/tmp/s" (make-string 64 #\b) "sha256")
           (extract-action "/tmp/s" "/tmp/stage")
           (run-step-action "compile" '("make" "-j4") "/tmp/stage")
           (install-file-action "/tmp/stage/a.el" "/pkg/a.el" #o644)
           (write-file-action "/pkg/pin" "9edb3f66")
           (symlink-action "/pkg/1.0" "/pkg/current")
           (remove-path-action "/tmp/stage"))))
  (check-equal?
   (plan->text golden-plan)
   (string-join
    (list (string-append "fetch https://example.org/r.git @ "
                         (make-string 40 #\a) " -> /tmp/s")
          (string-append "verify /tmp/s sha256:" (make-string 64 #\b))
          "extract /tmp/s -> /tmp/stage"
          "run-step compile [make -j4] in /tmp/stage"
          "install-file /tmp/stage/a.el -> /pkg/a.el mode 644"
          "write-file /pkg/pin (8 bytes)"
          "symlink /pkg/current -> /pkg/1.0"
          "remove-path /tmp/stage")
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

  ;; The input hash covers flags: flipping one flips the hash.
  (define alpha-off
    (derive-package-plan alpha-spec '((gui . #f)) '("pkg-beta 1.0")))
  (check-false (equal? (package-plan-input-hash alpha-plan)
                       (package-plan-input-hash alpha-off)))

  ;; derive-plans orders deps first; cycles raise kind 'resolve.
  (check-equal? (map package-plan-name
                     (derive-plans (list alpha-spec beta-spec) '() '()))
                '(pkg-beta pkg-alpha))
  (define cycle-spec
    (struct-copy spec alpha-spec
                 [name 'pkg-cycle-a]
                 [deps (list (dep 'pkg-cycle-a
                                  (string->version "2.0")))]))
  (check-pred resolve-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (derive-plans (list cycle-spec) '() '())
                'no-error))

  ;; Two slots of one package plan to two store dirs.
  (define alpha-alt
    (struct-copy spec alpha-spec [slot 'lts]))
  (check-false (equal? (package-plan-store-dir
                        (derive-package-plan alpha-spec '((gui . #t))
                                             '("pkg-beta 1.0")))
                       (package-plan-store-dir
                        (derive-package-plan alpha-alt '((gui . #t))
                                             '("pkg-beta 1.0")))))

  ;; Flags from another spec are caller error, kind 'config.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (derive-package-plan alpha-spec '((nope . #t))
                                     '("pkg-beta 1.0"))
                'no-error)))
