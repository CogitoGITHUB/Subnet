#lang racket/base
;; spec.rkt -- package spec structs and data predicates. Pure, no I/O.
;; Deep shape checks live in spec-read.rkt; guards here keep type-level
;; promises so an invalid value cannot exist (M-10).

(require racket/contract/base
         "errors.rkt"
         "version.rkt"
         "git-id.rkt")

(provide
 (struct-out source)
 (struct-out dep)
 (struct-out build-step)
 (struct-out install-spec)
 (struct-out variant-spec)
 (struct-out when-spec)
 (struct-out spec)
 (contract-out
  ;; any -> boolean, symbol matching D-8 names
  [package-name? (-> any/c boolean?)]))

;; ---------------------------------------------------------------------------
;; Names (D-8)

;; any -> boolean, [a-z0-9][a-z0-9-]* as a symbol
(define (package-name? v)
  (and (symbol? v)
       (regexp-match? #rx"^[a-z0-9][a-z0-9-]*$"
                      (symbol->string v))))

;; ---------------------------------------------------------------------------
;; Data

(struct source (url commit)
  #:transparent
  #:guard (lambda (url commit _name)
            (unless (and (string? url) (> (string-length url) 0))
              (raise-pm-error 'spec 'source "url must be a nonempty string"
                              #:fields `(("value" . ,url))))
            (unless (git-id? commit)
              (raise-pm-error 'spec 'source "not a commit id"
                              #:fields `(("value" . ,commit))))
            (values url commit)))
;; url    : string?  git URL (scheme checks happen in spec-read)
;; commit : string?  full commit id, 40 or 64 lowercase hex

(struct dep (name version)
  #:transparent
  #:guard (lambda (name version _n)
            (unless (package-name? name)
              (raise-pm-error 'spec 'dep "bad dependency name"
                              #:fields `(("value" . ,name))))
            (unless (version? version)
              (raise-pm-error 'spec 'dep "not a version"
                              #:fields `(("value" . ,version))))
            (values name version)))
;; name    : package-name?  depended-on package
;; version : version?       exact match only (D-007)

(struct build-step (name args)
  #:transparent
  #:guard (lambda (name args _n)
            (unless (symbol? name)
              (raise-pm-error 'spec 'build-step "step needs a symbol"
                              #:fields `(("value" . ,name))))
            (unless (list? args)
              (raise-pm-error 'spec 'build-step "args must be a list"
                              #:fields `(("value" . ,args))))
            (values name args)))
;; name : symbol?  closed step vocabulary, checked in spec-read
;; args : list?    plain data only

(struct install-spec (target forms)
  #:transparent
  #:guard (lambda (target forms _n)
            (unless (memq target '(emacs system))
              (raise-pm-error 'spec 'install-spec "unknown target"
                              #:fields `(("value" . ,target))))
            (unless (list? forms)
              (raise-pm-error 'spec 'install-spec "forms must be a list"
                              #:fields `(("value" . ,forms))))
            (values target forms)))
;; target : (or/c 'emacs 'system)  the core treats forms as opaque
;; forms  : list?                  target-validated later

(struct variant-spec (name overrides)
  #:transparent
  #:guard (lambda (name overrides _n)
            (unless (symbol? name)
              (raise-pm-error 'spec 'variant-spec "variant needs a name"
                              #:fields `(("value" . ,name))))
            (unless (list? overrides)
              (raise-pm-error 'spec 'variant-spec "overrides need a list"
                              #:fields `(("value" . ,overrides))))
            (values name overrides)))
;; name      : symbol?  variant picked by name at plan time
;; overrides : list?    field forms, validated in spec-read

(struct when-spec (cond fields)
  #:transparent
  #:guard (lambda (cond fields _n)
            (unless (list? cond)
              (raise-pm-error 'spec 'when-spec "cond needs a list"
                              #:fields `(("value" . ,cond))))
            (unless (list? fields)
              (raise-pm-error 'spec 'when-spec "fields need a list"
                              #:fields `(("value" . ,fields))))
            (values cond fields)))
;; cond   : list?  (platform OS) (emacs-version OP VER) (feature NAME)
;; fields : list?  field forms applied when cond holds

(struct spec (name version summary source deps build install
              license homepage extends variants whens)
  #:transparent
  #:guard (lambda (name version summary source deps build install
                   license homepage extends variants whens _n)
            (unless (package-name? name)
              (raise-pm-error 'spec 'spec "bad package name"
                              #:fields `(("value" . ,name))))
            (unless (version? version)
              (raise-pm-error 'spec 'spec "not a version"
                              #:fields `(("value" . ,version))))
            (unless (string? summary)
              (raise-pm-error 'spec 'spec "summary must be a string"
                              #:fields `(("value" . ,summary))))
            (unless (source? source)
              (raise-pm-error 'spec 'spec "not a source"
                              #:fields `(("value" . ,source))))
            (unless (and (list? deps) (andmap dep? deps))
              (raise-pm-error 'spec 'spec "deps must be dep structs"
                              #:fields `(("value" . ,deps))))
            (unless (and (list? build) (andmap build-step? build))
              (raise-pm-error 'spec 'spec "build must be build steps"
                              #:fields `(("value" . ,build))))
            (unless (install-spec? install)
              (raise-pm-error 'spec 'spec "not an install spec"
                              #:fields `(("value" . ,install))))
            (unless (symbol? license)
              (raise-pm-error 'spec 'spec "license must be a symbol"
                              #:fields `(("value" . ,license))))
            (unless (string? homepage)
              (raise-pm-error 'spec 'spec "homepage must be a string"
                              #:fields `(("value" . ,homepage))))
            (unless (or (not extends) (package-name? extends))
              (raise-pm-error 'spec 'spec "extends must be a name or #f"
                              #:fields `(("value" . ,extends))))
            (unless (and (list? variants) (andmap variant-spec? variants))
              (raise-pm-error 'spec 'spec "variants must be variant structs"
                              #:fields `(("value" . ,variants))))
            (unless (and (list? whens) (andmap when-spec? whens))
              (raise-pm-error 'spec 'spec "whens must be when structs"
                              #:fields `(("value" . ,whens))))
            (values name version summary source deps build install
                    license homepage extends variants whens)))
;; name     : package-name?  D-8
;; version  : version?       exact matching only (D-007)
;; summary  : string?
;; source   : source?        git URL plus full commit (D-006)
;; deps     : (listof dep?)  names plus exact versions
;; build    : (listof build-step?)  data steps with hooks later
;; install  : install-spec?  opaque per target
;; license  : symbol?
;; homepage : string?
;; extends  : (or/c package-name? #f)
;; variants : (listof variant-spec?)
;; whens    : (listof when-spec?)

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit)

  ;; Names accept D-8, reject the rest.
  (check-true (package-name? 'racket-mode))
  (check-true (package-name? 'a))
  (check-false (package-name? 'Bad!))
  (check-false (package-name? 'a/b))
  (check-false (package-name? "racket-mode"))
  (check-false (package-name? ""))

  ;; A full valid spec builds.
  (define good
    (spec 'racket-mode (string->version "20250115.1432") "Racket in Emacs"
          (source "https://example.org/r.git"
                  "9edb3f66fd807b096b48283debdcddccfea34bad")
          (list (dep 'compat (string->version "1.0")))
          (list (build-step 'byte-compile '()))
          (install-spec 'emacs '((autoloads "r-autoloads.el")))
          'gpl-3.0+ "https://example.org/r" #f '() '()))
  (check-true (spec? good))
  (check-equal? (spec-name good) 'racket-mode)

  ;; Every guard rejects with kind 'spec.
  (define (spec-kind thunk)
    (with-handlers ([exn:fail:pm? exn:fail:pm-kind])
      (thunk)
      #f))
  (check-eq? (spec-kind (lambda () (source "" "abc"))) 'spec)
  (check-eq? (spec-kind (lambda () (source "u" "XYZ"))) 'spec)
  (check-eq? (spec-kind (lambda () (dep 'Bad! good))) 'spec)
  (check-eq? (spec-kind (lambda () (install-spec 'web '()))) 'spec)
  (check-eq? (spec-kind
              (lambda ()
                (struct-copy spec good [name 'Bad!]))) 'spec)
  (check-eq? (spec-kind
              (lambda ()
                (struct-copy spec good [extends 'Bad!]))) 'spec))
