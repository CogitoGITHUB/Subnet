#lang racket/base
;; ecosystem.rkt -- package-kind templates (E-25, D-032). Pure: read a
;; validated .rktd from ecosystems/, expand its build steps under spec
;; overrides. An ecosystem EXPANDS into the existing closed build-step
;; vocabulary and adds no new step types: step names and required keys
;; share spec-read's validators, so the two files cannot drift apart.
;; Host tools are DATA here (ecosystem-tools); the build backend
;; checks them before spawning anything. Install layout stays
;; per-spec for now (specs already carry install forms); no ecosystem
;; install defaults are read yet.

(require racket/contract/base
         racket/path
         racket/string
         "../errors/error-type.rkt"
         "./spec.rkt"
         "./spec-read.rkt")

(provide
 (struct-out ecosystem)
 (contract-out
  ;; path-string -> ecosystem, validated or kind 'spec naming the file
  [read-ecosystem-file (-> path-string? ecosystem?)]
  ;; ecosystem (listof build-step) -> (listof build-step), merged
  [expand-steps (-> ecosystem? (listof build-step?) (listof build-step?))]
  ;; ecosystem spec -> (values (listof string) (listof build-step)): the
  ;; tools the build backend must preflight, plus the resolved steps
  [expand-spec (-> ecosystem? spec? (values (listof string?)
                                            (listof build-step?)))]))

(struct ecosystem (name tools steps)
  #:transparent
  #:guard (lambda (name tools steps _n)
            (unless (symbol? name)
              (raise-pm-error 'spec 'ecosystem "name must be a symbol"
                              #:fields `(("value" . ,(format "~s" name)))))
            (unless (and (list? tools) (andmap string? tools))
              (raise-pm-error 'spec 'ecosystem "tools must be strings"
                              #:fields `(("value" . ,(format "~s" tools)))))
            (unless (and (list? steps) (andmap build-step? steps))
              (raise-pm-error 'spec 'ecosystem "steps must be build steps"
                              #:fields `(("value" . ,(format "~s" steps)))))
            (values name tools steps)))
;; name  : symbol?             package kind, matches the file stem
;; tools : (listof string?)   required host tools, checked at build
;; steps : (listof build-step?) closed-vocabulary template

;; string path -> never returns, kind 'spec naming the file
(define (eco-fail file message fields)
  (raise-pm-error 'spec 'read-ecosystem-file message
                  #:fields (cons `("file" . ,file) fields)))

;; path-string -> string, file stem, .rktd suffix required
(define (eco-stem path file)
  (define base (path->string (file-name-from-path (string->path path))))
  (unless (string-suffix? base ".rktd")
    (eco-fail file "ecosystem file needs .rktd suffix" '()))
  (substring base 0 (- (string-length base) 5)))

;; any path -> build-step, closed name plus required keys present
(define (eco-read-step s file)
  (unless (and (pair? s) (symbol? (car s)))
    (eco-fail file "step must be (NAME ARG ...)"
              `(("step" . ,(format "~s" s)))))
  (define step-name (car s))
  (unless (valid-build-step? step-name)
    (eco-fail file (format "unknown build step '~a" step-name) '()))
  (for ([k (in-list (step-required-keys step-name))])
    (unless (member k (cdr s))
      (eco-fail file (format "step '~a needs ~a" step-name k) '())))
  (build-step step-name (cdr s)))

;; any path -> ecosystem, exactly name/tools/build, validated
(define (eco-read-datum datum path)
  (define file (if (path? path) (path->string path) path))
  (unless (and (pair? datum) (eq? (car datum) 'ecosystem))
    (eco-fail file "must be an (ecosystem ...) declaration" '()))
  (define forms (cdr datum))
  (for ([f (in-list forms)])
    (unless (and (pair? f) (memq (car f) '(name tools build)))
      (eco-fail file "unknown ecosystem field"
                `(("field" . ,(format "~s" (if (pair? f) (car f) f)))))))
  (define (one-field head)
    (define hits (filter (lambda (f) (eq? (car f) head)) forms))
    (unless (= 1 (length hits))
      (eco-fail file (format "needs exactly one ~a field" head) '()))
    (cdr (car hits)))
  (define raw-name (one-field 'name))
  (unless (and (pair? raw-name) (symbol? (car raw-name)) (null? (cdr raw-name)))
    (eco-fail file "name must be (NAME)" '()))
  (define name (car raw-name))
  (unless (string=? (symbol->string name) (eco-stem path file))
    (eco-fail file "name must match the file stem" '()))
  (define raw-tools (one-field 'tools))
  (unless (and (pair? raw-tools) (list? (car raw-tools)))
    (eco-fail file "tools must be (STR ...)" '()))
  (define tools (car raw-tools))
  (unless (andmap string? tools)
    (eco-fail file "tools must be (STR ...)" '()))
  (define raw-build (one-field 'build))
  (unless (and (pair? raw-build)
               (pair? (car raw-build))
               (eq? (caar raw-build) 'steps))
    (eco-fail file "build must be (steps STEP ...)" '()))
  (ecosystem name tools
             (map (lambda (s) (eco-read-step s file))
                  (cdar raw-build))))

;; path-string -> ecosystem
(define (read-ecosystem-file path)
  (eco-read-datum (call-with-input-file path read) path))

;; ecosystem (listof build-step) -> (listof build-step). Ecosystem
;; order kept; a spec step with the same name replaces in place;
;; spec-only steps append. Specs override only differences.
(define (expand-steps eco overrides)
  (define table
    (for/hash ([s (in-list overrides)])
      (values (build-step-name s) s)))
  (define kept-steps
    (for/list ([s (in-list (ecosystem-steps eco))])
      (hash-ref table (build-step-name s) s)))
  (define eco-names (map build-step-name (ecosystem-steps eco)))
  (define extra
    (filter (lambda (s) (not (member (build-step-name s) eco-names)))
            overrides))
  (append kept-steps extra))

;; ecosystem spec -> (values tools steps). The whole E-25 surface in
;; one call: the backend preflights TOOLS, then runs STEPS. Pure.
(define (expand-spec eco spec)
  (values (ecosystem-tools eco)
          (expand-steps eco (spec-build spec))))

;; ---------------------------------------------------------------------------
