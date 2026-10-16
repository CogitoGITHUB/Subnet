#lang racket/base
;; plan-actions.rkt -- the twelve action structs, plan and package-plan,
;; with the guards that keep their promises. It must not lower, render,
;; hash or derive anything.

(require
 "../errors/error-type.rkt"
 "../git/git-commit.rkt"
 "spec.rkt"
 "../entry/version.rkt")

(provide
 ;; The twelve actions (A-3: values first, effects at the edge)
 (struct-out fetch-action)
 (struct-out extract-action)
 (struct-out run-step-action)
 (struct-out install-file-action)
 (struct-out write-file-action)
 (struct-out symlink-action)
 (struct-out remove-path-action)
 (struct-out export-action)
 (struct-out check-action)
 (struct-out mark-incomplete-action)
 (struct-out clear-incomplete-action)
 (struct-out set-current-action)
 ;; The two containers every later stage reads
 (struct-out plan)
 (struct-out package-plan)
 ;; any -> boolean, one of the twelve action kinds
 action?
 ;; (listof action) -> plan
 list->plan
 ;; The guard the twelve action guards share. It lives here because the
 ;; guards are its only callers; plan-derive re-provides it so the file
 ;; that reasons about plan fields can still reach it one way up.
 check-string-fields)

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
;; Actions (A-3: values first, effects at the edge; paths stay strings
;; here so plans print and diff stably; the local backend converts at its
;; edge)

(struct fetch-action (url commit dest)
  #:transparent
  #:guard (lambda (url commit dest _n)
            (check-string-fields 'fetch-action
                                 `(("url" . ,url) ("commit" . ,commit)
                                   ("dest" . ,dest)))
            (values url commit dest)))
;; url commit dest : string?  what to fetch, exact pin, where to stage it

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

;; E-06 field shapes (minimal picks not specified in the docs; recorded
;; in ENGINE.org with this commit): export carries the vault namespace
;; name, pin and staging dir (mirrors fetch-action); check carries the
;; check program+args and the versioned prefix dir it runs in (after
;; placement, before the marker is cleared, D-028); the marker actions
;; carry the versioned dir; set-current mirrors symlink-action because
;; the flip IS a symlink (target versioned dir, link <name>/current).
(struct export-action (package pin dest)
  #:transparent
  #:guard (lambda (package pin dest _n)
            (unless (symbol? package)
              (raise-pm-error 'internal 'export-action
                              "package must be a symbol"
                              #:fields `(("value" . ,package))))
            (check-string-fields 'export-action
                                 `(("pin" . ,pin)
                                   ("dest" . ,dest)))
            (values package pin dest)))
;; package : symbol?  D-8 name, the vault namespace to export from
;; pin dest : string?  exact commit id, staging dir receiving the tree

(struct check-action (argv cwd)
  #:transparent
  #:guard (lambda (argv cwd _n)
            (unless (and (list? argv) (andmap string? argv)
                         (pair? argv))
              (raise-pm-error 'internal 'check-action
                              "argv must be a nonempty string list"
                              #:fields `(("value" . ,argv))))
            (check-string-fields 'check-action `(("cwd" . ,cwd)))
            (values argv cwd)))
;; argv : (nonempty-listof string?)  check program and args, exact
;; cwd : string?  versioned prefix dir the check runs in

(struct mark-incomplete-action (dir)
  #:transparent
  #:guard (lambda (dir _n)
            (check-string-fields 'mark-incomplete-action
                                 `(("dir" . ,dir)))
            (values dir)))
;; dir : string?  versioned dir gaining .pm-incomplete

(struct clear-incomplete-action (dir)
  #:transparent
  #:guard (lambda (dir _n)
            (check-string-fields 'clear-incomplete-action
                                 `(("dir" . ,dir)))
            (values dir)))
;; dir : string?  versioned dir losing .pm-incomplete after check passes

(struct set-current-action (target link)
  #:transparent
  #:guard (lambda (target link _n)
            (check-string-fields 'set-current-action
                                 `(("target" . ,target)
                                   ("link" . ,link)))
            (values target link)))
;; target link : string?  versioned dir, <name>/current link flipping to it

;; any -> boolean, one of the twelve action kinds below
(define (action? v)
  (or (fetch-action? v) (extract-action? v)
      (run-step-action? v) (install-file-action? v)
      (write-file-action? v) (symlink-action? v)
      (remove-path-action? v) (export-action? v)
      (check-action? v) (mark-incomplete-action? v)
      (clear-incomplete-action? v) (set-current-action? v)))

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
;; Package plans (E-04: spec + resolved flags + dep identities -> values)

;; A package plan is pure values: everything lowering (E-06) and the lock
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
;; input-hash : string?  sha1 hex over the canonical rendering in
;;                         plan-hash.rkt

;; ---------------------------------------------------------------------------
;; Guards reject with kind 'internal (programmer-side construction) or
;; 'spec (a declaration that cannot become a plan).

(module+ test
  (require rackunit
           "../errors/error-type.rkt")

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
                (plan '(oops)))))
