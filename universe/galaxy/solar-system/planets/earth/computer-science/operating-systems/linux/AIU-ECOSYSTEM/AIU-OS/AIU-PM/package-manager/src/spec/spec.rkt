#lang racket/base
;; spec.rkt -- package spec structs and data predicates. Pure, no I/O.
;; Deep shape checks live in spec-read.rkt; guards here keep type-level
;; promises so an invalid value cannot exist (M-10).

(require racket/contract/base
          "../errors/error-type.rkt"
          "./version.rkt"
          "../errors/git-id.rkt"
          "../errors/package-name.rkt")

(provide
 (struct-out source)
 (struct-out dep)
 (struct-out build-step)
 (struct-out install-spec)
 (struct-out variant-spec)
 (struct-out when-spec)
 (struct-out flag-spec)
 (struct-out spec)
 (contract-out
  ;; any -> boolean, symbol matching D-8 names
  [package-name? (-> any/c boolean?)]
  ;; any -> boolean, slot stream names (D-023)
  [slot-name? (-> any/c boolean?)]))

;; ---------------------------------------------------------------------------
;; Names (D-8)

;; any -> boolean, [a-z0-9][a-z0-9-]* as a symbol
(define (package-name? v)
  (and (symbol? v)
       (regexp-match? #rx"^[a-z0-9][a-z0-9-]*$"
                      (symbol->string v))))

;; any -> boolean, a slot stream name (D-023): letters, digits, dot,
;; underscore and dash, never empty. Dots let a slot track a version
;; stream like "5.5", which D-8 names forbid.
(define (slot-name? v)
  (and (symbol? v)
       (regexp-match? #rx"^[A-Za-z0-9][A-Za-z0-9._-]*$"
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
            (unless (memq target '(prefix))
              (raise-pm-error 'spec 'install-spec "unknown target"
                              #:fields `(("value" . ,target))))
            (unless (list? forms)
              (raise-pm-error 'spec 'install-spec "forms must be a list"
                              #:fields `(("value" . ,forms))))
            (values target forms)))
;; target : (or/c 'prefix)  v1 has one target: the versioned prefix dir.
;;   A new target = a new head symbol + form validator + backend.
;; forms  : list?  kind-checked install forms, validated in spec-read

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
;; cond   : list?  (platform OS) (feature NAME)
;; fields : list?  field forms applied when cond holds

;; USE-style flag declaration (D-022). Resolution against config lives in
;; flags.rkt (E-03); this struct only says the declaration itself is sound.
(struct flag-spec (name default doc conflicts requires)
  #:transparent
  #:guard (lambda (name default doc conflicts requires _n)
            (unless (package-name? name)
              (raise-pm-error 'spec 'flag-spec "bad flag name"
                              #:fields `(("value" . ,name))))
            (unless (boolean? default)
              (raise-pm-error 'spec 'flag-spec "default must be a boolean"
                              #:fields `(("value" . ,default))))
            (unless (and (string? doc) (> (string-length doc) 0))
              (raise-pm-error 'spec 'flag-spec "doc must be a nonempty string"
                              #:fields `(("value" . ,doc))))
            (unless (and (list? conflicts)
                         (andmap package-name? conflicts))
              (raise-pm-error 'spec 'flag-spec "conflicts must be flag names"
                              #:fields `(("value" . ,conflicts))))
            (unless (and (list? requires)
                         (andmap package-name? requires))
              (raise-pm-error 'spec 'flag-spec "requires must be flag names"
                              #:fields `(("value" . ,requires))))
            (values name default doc conflicts requires)))
;; name      : package-name?  flag vocabulary of this package (D-8)
;; default   : boolean?       spec default, config may override (D-022)
;; doc       : string?        one-line description
;; conflicts : (listof package-name?)  never enabled together (checked E-03)
;; requires  : (listof package-name?)  must be enabled too (checked E-03)

(struct spec (name version summary source deps build-deps build install
              license homepage extends variants whens slot flags)
  #:transparent
  #:guard (lambda (name version summary source deps build-deps build install
                   license homepage extends variants whens slot flags _n)
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
            (unless (and (list? build-deps) (andmap dep? build-deps))
              (raise-pm-error 'spec 'spec "build-deps must be dep structs"
                              #:fields `(("value" . ,build-deps))))
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
            (unless (slot-name? slot)
              (raise-pm-error 'spec 'spec "bad slot name"
                              #:fields `(("value" . ,slot))))
            (unless (and (list? flags) (andmap flag-spec? flags))
              (raise-pm-error 'spec 'spec "flags must be flag structs"
                              #:fields `(("value" . ,flags))))
            (values name version summary source deps build-deps build install
                    license homepage extends variants whens slot flags)))
;; name     : package-name?  D-8
;; version  : version?       exact matching only (D-007)
;; summary  : string?
;; source   : source?        git URL plus full commit (D-006)
;; deps     : (listof dep?)  run-time edges, names plus exact versions
;; build-deps : (listof dep?)  build-time only, absent from activation
;; build    : (listof build-step?)  data steps with hooks later
;; install  : install-spec?  opaque per target
;; license  : symbol?
;; homepage : string?
;; extends  : (or/c package-name? #f)
;; variants : (listof variant-spec?)
;; whens    : (listof when-spec?)
;; slot     : slot-name?   version stream, 'default when undeclared (D-023)
;; flags    : (listof flag-spec?)  declared USE-style flags (D-022)

;; ---------------------------------------------------------------------------
