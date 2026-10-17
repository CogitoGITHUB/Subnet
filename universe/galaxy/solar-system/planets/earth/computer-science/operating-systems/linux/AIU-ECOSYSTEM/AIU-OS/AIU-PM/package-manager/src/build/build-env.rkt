#lang racket/base
;; build-env.rkt -- the environment a build step runs in: its args as
;; data, where it may run, and the extras handed to run-command (D-025,
;; SPEC-NEUTRAL section 5). LANG, a staging-fake HOME inside work, and
;; the three directory pointers; PATH and CC come from the parent; this
;; module never reads the environment itself, and no HOME, XDG or
;; find-system-path appears outside the tests. Relative step dirs
;; resolve under the work root first (the caller exports the source
;; tree there) and fall back to the source dir; absolute paths and ..
;; escapes refuse with kind 'config.
;;
;; The public contract for build-env lives on the facade
;; (build-plan.rkt); the helpers below are the internal API the
;; build-systems modules build commands from.

(require racket/file
         racket/list
         racket/path
         racket/string
         "../errors/error-type.rkt")

(provide
 ;; #:prefix #:source #:work -> env extras for run-command
 build-env
 ;; small datum helpers: spec args are plain data (keywords, strings,
 ;; lists of strings or pairs)
 arg-val
 as-strings
 as-string
 pairs->flags
 vars->flags
 expand-prefix
 ;; path discipline: work first, source as fallback; builddir always
 ;; under work; absolute paths and .. escapes refuse
 check-confined
 resolve-dir
 resolve-builddir)

;; ---------------------------------------------------------------------------
;; Environment (D-025, SPEC-NEUTRAL section 5): LANG, a staging-fake
;; HOME inside work, and the three directory pointers. PATH reaches the
;; child through run.rkt's allowlist; callers add overrides via #:env.

;; #:prefix #:source #:work -> env extras
(define (build-env #:prefix prefix #:source source #:work work)
  (define home (build-path work "fake-home"))
  (make-directory* home)
  ;; G-09: builds run without ambient network configuration. The proxy
  ;; variables are emptied (not merely dropped: an empty proxy means no
  ;; proxy to every tool that reads them), so a build cannot reach the
  ;; network through the user's proxy setup and cannot present ambient
  ;; proxy credentials. Blocking direct connections needs a sandbox pm
  ;; does not have; that limit is stated in ENGINE.org, not hidden.
  (append (list (cons "LANG" "C.UTF-8")
                (cons "HOME" (path->string home))
                (cons "PREFIX" (if (path? prefix)
                                   (path->string prefix)
                                   prefix))
                (cons "SRCDIR" (if (path? source)
                                   (path->string source)
                                   source))
                (cons "BUILDDIR" (if (path? work)
                                     (path->string work)
                                     work)))
          (for/list ([v (in-list '("http_proxy" "https_proxy"
                                   "HTTP_PROXY" "HTTPS_PROXY"))])
            (cons v ""))))

;; ---------------------------------------------------------------------------
;; Small datum helpers (spec args are plain data: keywords, strings,
;; lists of strings or pairs).

;; (listof any) keyword any -> any, value after KW or DEFAULT
(define (arg-val args kw default)
  (let loop ([rest args])
    (cond [(null? rest) default]
          [(and (keyword? (car rest)) (equal? (car rest) kw))
           (if (pair? (cdr rest)) (cadr rest) default)]
          [else (loop (cdr rest))])))

;; any -> (listof string), single string counts as one
(define (as-strings v)
  (cond [(string? v) (list v)]
        [(list? v) (filter string? v)]
        [else '()]))

;; any string -> string
(define (as-string v default)
  (if (string? v) v default))

;; any -> (listof string), NAME=VALUE flags from pairs or bare strings
(define (pairs->flags v flag-prefix)
  (cond [(list? v)
         (for/list ([item (in-list v)]
                    #:when (or (string? item)
                               (and (list? item)
                                    (= 2 (length item)))))
           (if (string? item)
               (if (string-prefix? item flag-prefix)
                   item
                   (string-append flag-prefix item))
               (string-append flag-prefix
                              (format "~a=~a" (first item)
                                      (second item)))))]
        [else '()]))

;; any -> (listof string), NAME=VALUE without a prefix
(define (vars->flags v)
  (cond [(list? v)
         (for/list ([item (in-list v)]
                    #:when (or (string? item)
                               (and (list? item)
                                    (= 2 (length item)))))
           (if (string? item)
               item
               (format "~a=~a" (first item) (second item))))]
        [else '()]))

;; string string -> string, every $PREFIX becomes the prefix path
(define (expand-prefix s prefix)
  (string-replace s "$PREFIX" prefix))

;; ---------------------------------------------------------------------------
;; Path discipline: work first, source as fallback; builddir always
;; under work; absolute paths and .. escapes refuse (kind 'config).

;; string -> void, absolute or escaping paths never run
(define (check-confined rel step-name)
  (define p (string->path rel))
  (when (or (absolute-path? p)
            (member 'up (explode-path p)))
    (raise-pm-error 'config 'execute-build-step
                    "step path escapes the work root"
                    #:fields `(("step" . ,(symbol->string step-name))
                               ("path" . ,rel)))))

;; symbol string path path -> path, work first then source
(define (resolve-dir step-name rel work source)
  (check-confined rel step-name)
  (define w (build-path work rel))
  (if (or (directory-exists? w) (file-exists? w))
      w
      (build-path source rel)))

;; string path -> path, build outputs always live under work
(define (resolve-builddir rel work step-name)
  (check-confined rel step-name)
  (define b (build-path work rel))
  (make-directory* b)
  b)

;; ---------------------------------------------------------------------------
