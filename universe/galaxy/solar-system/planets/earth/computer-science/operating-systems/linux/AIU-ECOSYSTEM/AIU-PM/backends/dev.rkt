#lang racket/base
;; dev.rkt -- dev checkouts: link, build against, install from, status
;; (docs/DEV-MODE.org, E-19). A dev package installs from a live
;; checkout instead of a vault pin: the link record lives in the state
;; dir (dev-links.rktd: name, checkout path, branch policy), builds
;; run unmodified with srcdir=checkout, and install forms place
;; symlinks into the checkout instead of copying. The current link
;; points at the prefix as usual, so activation and rollback treat
;; dev and normal packages identically. Fingerprints, branch policy
;; enforcement, strict modes and update flows are later items; the
;; policy string is stored opaque here. No vault writes, no network.

(require racket/contract/base
         racket/file
         racket/list
         racket/path
         racket/string
         "../core/errors.rkt"
         "../core/spec.rkt")

(provide
 (contract-out
  ;; string path-string string path-string -> void, register a checkout
  [dev-link! (-> string? path-string? string? path-string? void?)]
  ;; string path-string -> void, release a checkout (idempotent)
  [dev-unlink! (-> string? path-string? void?)]
  ;; path-string -> (listof list), (name checkout policy) records
  [dev-links (-> path-string? (listof list?))]
  ;; string path-string -> boolean, is the package dev-linked
  [dev-linked? (-> string? path-string? boolean?)]
  ;; string path-string -> list, status datum flagging dev
  [dev-status (-> string? path-string? (list/c string? string? symbol?))]
  ;; list path-string path-string -> void, symlink placement for dev
  [dev-install! (-> list? path-string? path-string? void?)]))

;; string -> void, real D-8 package names only
(define (check-dev-name name)
  (unless (and (string? name) (package-name? (string->symbol name)))
    (raise-pm-error 'config 'dev-link! "bad package name"
                    #:fields `(("name" . ,(format "~s" name))))))

;; path-string -> path, the links file (absent reads as none linked)
(define (dev-links-file state)
  (build-path state "dev-links.rktd"))

;; path-string -> (listof list), validated records or kind 'config
(define (dev-links state)
  (define f (dev-links-file state))
  (if (not (file-exists? f))
      '()
      (let ([datum (read-dev-links-file f)])
        (if (and (list? datum) (andmap dev-record? datum))
            datum
            (raise-dev-bad f)))))

;; path -> jsexpr, one file read; failures become kind 'config
(define (read-dev-links-file f)
  (with-handlers ([exn:fail? (lambda (e) (raise-dev-bad f))])
    (call-with-input-file f read)))

;; any -> boolean, one (name checkout policy) record of strings
(define (dev-record? v)
  (and (list? v)
       (= 3 (length v))
       (string? (first v))
       (string? (second v))
       (string? (third v))))

;; path -> never returns, kind 'config naming the file
(define (raise-dev-bad f)
  (raise-pm-error 'config 'dev-links "bad dev-links file"
                  #:fields `(("file" . ,(path->string f)))))

;; path-string (listof list) -> void
(define (write-dev-links! state links)
  (make-directory* state)
  (call-with-output-file (dev-links-file state)
    (lambda (out) (write links out))
    #:exists 'truncate/replace))

;; string path-string string path-string -> void, register a checkout.
;; Refuses twice-linking, bad names and missing checkouts loudly.
(define (dev-link! name checkout policy state)
  (check-dev-name name)
  (unless (directory-exists? checkout)
    (raise-pm-error 'config 'dev-link! "checkout missing"
                    #:fields `(("package" . ,name)
                                ("checkout" . ,(if (path? checkout)
                                                   (path->string checkout)
                                                   checkout)))))
  (unless (string? policy)
    (raise-pm-error 'config 'dev-link! "bad branch policy"
                    #:fields `(("package" . ,name))))
  (define links (dev-links state))
  (when (assoc name links)
    (raise-pm-error 'config 'dev-link! "already linked"
                    #:fields `(("package" . ,name))
                    #:hint "undev first to change it"))
  (write-dev-links! state (append links (list (list name
                                                    (if (path? checkout)
                                                        (path->string checkout)
                                                        checkout)
                                                    policy)))))

;; string path-string -> void, release a checkout (idempotent: an
;; unlinked name is already unlinked, never an error)
(define (dev-unlink! name state)
  (define links (dev-links state))
  (define kept (filter (lambda (r) (not (equal? (car r) name))) links))
  (unless (= (length kept) (length links))
    (write-dev-links! state kept)))

;; string path-string -> boolean
(define (dev-linked? name state)
  (if (assoc name (dev-links state)) #t #f))

;; string path-string -> list, status datum flagging dev. The third
;; field is always 'dev: presence in the links file IS the flag.
(define (dev-status name state)
  (define hit (assoc name (dev-links state)))
  (unless hit
    (raise-pm-error 'config 'dev-status "package not dev-linked"
                    #:fields `(("package" . ,name))))
  (list name (second hit) 'dev))

;; string string string string -> path, inside-base or kind 'config.
;; Mirrors local.rkt confine: dev symlinks must not escape either end.
(define (dev-confine base what rel name)
  (define p (string->path rel))
  (when (or (absolute-path? p) (member 'up (explode-path p)))
    (raise-pm-error 'config 'dev-install! "install path escapes"
                    #:fields `(("package" . ,name)
                                ("field" . ,what)
                                ("path" . ,rel))))
  (build-path base rel))

;; list path-string path-string -> void, symlink placement for dev.
;; Two-arg kind forms link prefix/DST at checkout/SRC; symlink forms
;; link inside the prefix like normal; mode forms apply to nothing
;; (targets keep checkout modes) so they pass silently by design;
;; one-arg owning forms and unknown heads refuse (untested combos).
(define (dev-install! forms checkout prefix)
  (define name "dev")
  (for ([form (in-list forms)])
    (unless (and (pair? form) (symbol? (car form)))
      (raise-pm-error 'config 'dev-install! "bad install form"
                      #:fields `(("form" . ,(format "~s" form)))))
    (case (car form)
      [(bin lib include share man libexec)
       (define rels (filter string? (cdr form)))
       (when (null? rels)
         (raise-pm-error 'config 'dev-install! "form needs a path"
                         #:fields `(("form" . ,(format "~s" form)))))
       (define dst (if (and (pair? rels) (pair? (cdr rels)))
                         (cadr rels)
                         (car rels)))
       (define src (dev-confine checkout "src" (car rels) name))
       (define dst-p (dev-confine prefix "dst" dst name))
       (unless (or (file-exists? src) (directory-exists? src))
         (raise-pm-error 'config 'dev-install! "checkout source missing"
                         #:fields `(("src" . ,(path->string src)))))
       (make-directory* (or (path-only dst-p) prefix))
       (when (or (link-exists? dst-p) (file-exists? dst-p))
         (delete-file dst-p))
       (when (directory-exists? dst-p)
         (raise-pm-error 'config 'dev-install! "link path occupied"
                         #:fields `(("dst" . ,(path->string dst-p)))))
       (make-file-or-directory-link (path->string src) dst-p)]
      [(symlink)
       (define args (filter string? (cdr form)))
       (unless (= 2 (length args))
         (raise-pm-error 'config 'dev-install! "symlink needs LINK TARGET"
                         #:fields `(("form" . ,(format "~s" form)))))
       (define link-p (dev-confine prefix "link" (car args) name))
       (make-directory* (or (path-only link-p) prefix))
       (when (or (link-exists? link-p) (file-exists? link-p))
         (delete-file link-p))
       (make-file-or-directory-link (cadr args) link-p)]
      [(mode check) (void)]
      [else
       (raise-pm-error 'config 'dev-install! "form needs a built tree"
                       #:fields `(("form" . ,(format "~s" form))))])))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/path
           "activate.rkt"
           "build.rkt"
           "local.rkt"
           "../core/errors.rkt"
           "../core/plan.rkt"
           "../core/spec.rkt")

  ;; All fixtures are synthetic (T-10) under one temp root: a fake
  ;; checkout, a state dir, a prefix. Nothing leaves temp.
  (define test-root (make-temporary-directory "pm-dev~a"))
  (define state (build-path test-root "state"))
  (define checkout (build-path test-root "checkout"))
  (make-directory* (build-path checkout "bin"))
  (call-with-output-file (build-path checkout "bin" "prog.sh")
    (lambda (out) (display "prog-bytes" out)))
  (call-with-output-file (build-path checkout "inc.h")
    (lambda (out) (display "inc-bytes" out)))
  (define prefix (build-path test-root "prefix"))

  ;; Link, read back, status flags dev; twice-linking refuses.
  (dev-link! "pkg-dev" checkout "tip" state)
  (check-true (dev-linked? "pkg-dev" state))
  (check-equal? (dev-status "pkg-dev" state)
                (list "pkg-dev" (path->string checkout) 'dev))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-link! "pkg-dev" checkout "tip" state)
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-link! "Bad!" checkout "tip" state)
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-link! "pkg-gone" (build-path test-root "nowhere")
                           "tip" state)
                'no-error))
  ;; Unlink releases; twice-unlink stays void; status then refuses.
  (dev-unlink! "pkg-dev" state)
  (check-false (dev-linked? "pkg-dev" state))
  (check-not-exn (lambda () (dev-unlink! "pkg-dev" state)))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-status "pkg-dev" state)
                'no-error))
  (dev-link! "pkg-dev" checkout "tip" state)

  ;; Install links prefix paths at checkout files; modes pass over.
  (dev-install! '((bin "bin/prog.sh" "bin/prog")
                  (include "inc.h" "include/inc.h")
                  (mode "bin/prog" 493))
                checkout prefix)
  (check-equal? (file->string (build-path prefix "bin" "prog"))
                "prog-bytes")
  (check-equal? (path->string (resolve-path (build-path prefix "bin" "prog")))
                (path->string (build-path checkout "bin" "prog.sh")))
  ;; Escapes, missing sources and built-tree forms refuse loudly.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-install! '((bin "x" "../escape")) checkout prefix)
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-install! '((bin "missing" "bin/missing")) checkout prefix)
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (dev-install! '((bin "bin/prog")) checkout prefix)
                'no-error))

  ;; End to end: a dev checkout flows mark, in-place build, symlink
  ;; install, check, clear and current, then activates normally with
  ;; generation links resolving into the checkout itself.
  (define co2 (build-path test-root "co2"))
  (make-directory co2)
  (call-with-output-file (build-path co2 "build.sh")
    (lambda (out) (display "#!/bin/sh\nprintf dev-bytes > built.txt\n" out)))
  (call-with-output-file (build-path co2 "makefile")
    (lambda (out) (display "all:\n\tsh build.sh\n" out)))
  (define ver2 (build-path test-root "ver2"))
  (define cur2 (build-path test-root "cur2"))
  (dev-link! "pkg-e2e" co2 "tip" state)
  (local-perform! (list->plan (list (mark-incomplete-action
                                     (path->string ver2)))))
  (execute-build-steps (list (build-step 'make '(#:dir "."
                                                  #:targets ("all"))))
                       #:source co2 #:work co2 #:prefix ver2)
  (dev-install! '((bin "built.txt" "bin/built")) co2 ver2)
  (local-perform! (list->plan (list (check-action '("cat" "bin/built")
                                                   (path->string ver2))
                                    (clear-incomplete-action
                                     (path->string ver2))
                                    (set-current-action
                                     (path->string ver2)
                                     (path->string cur2)))))
  (check-equal? (file->string (build-path cur2 "bin" "built")) "dev-bytes")
  (define prof2 (build-path test-root "profile2"))
  (define gen-e2e (profile-activate (list (list "pkg-e2e" ver2
                                                '("bin/built")))
                                    prof2))
  (check-equal? (file->string (build-path gen-e2e "bin" "built")) "dev-bytes")
  (check-true (dev-linked? "pkg-e2e" state))
  (delete-directory/files test-root))
