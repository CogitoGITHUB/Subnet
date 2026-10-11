#lang racket/base
;; activate.rkt -- own the profile: generations plus the atomic swap
;; (ENGINE.org backends/activate.rkt, SPEC-NEUTRAL section 4, E-13).
;;
;; Generations are profile-NNN/ dirs holding REAL subdirectories with
;; symlinks to files inside each package's current tree (absolute
;; targets; a moved store shows as stale links, which pm status
;; reports). Activate validates everything first, builds the next
;; generation, then flips the profile link with store.rkt's atomic
;; swap: a conflict fails closed with kind 'activate (exit 9) before
;; anything changes. No precedence rules, no last-wins. Rollback,
;; remove and hold are E-15 and live here later; the writer lock is a
;; caller (CLI) concern per E-12c, not this module's. Ownership comes
;; in explicitly as (name dir rels) triples; the manifest will supply
;; them from E-14 on.

(require racket/contract/base
         racket/file
         racket/list
         racket/path
         racket/string
         "store.rkt"
         "../core/errors.rkt")

(provide
 (contract-out
  ;; (listof entry) path-string -> path, next generation, profile flips
  [profile-activate (-> (listof (list/c string? path-string?
                                        (listof string?)))
                        path-string?
                        path?)]
  ;; path-string -> (listof path), existing generations oldest first
  [profile-generations (-> path-string? (listof path?))]))

;; exact-integer -> string, profile-001 style, sortable as text
(define (gen-dir-name n)
  (define digits (number->string n))
  (string-append "profile-"
                 (make-string (max 0 (- 3 (string-length digits))) #\0)
                 digits))

;; path -> exact-integer, one past the highest generation number
(define (next-gen-number profile-root)
  (define nums
    (for/list ([p (in-list (profile-generations profile-root))])
      (define m (regexp-match #rx"profile-([0-9]+)$"
                              (path->string (file-name-from-path p))))
      (string->number (second m))))
  (if (null? nums) 1 (+ 1 (apply max nums))))

;; path-string -> (listof path), existing generations oldest first
(define (profile-generations profile-root)
  (if (not (directory-exists? profile-root))
      '()
      (sort (for/list ([p (in-list (directory-list profile-root))]
                       #:when (regexp-match? #rx"^profile-[0-9]+$"
                                             (path->string p)))
              (build-path profile-root p))
            path<?)))

;; string -> void, single-segment package names only
(define (check-entry-name name)
  (unless (and (string? name)
               (not (string=? name ""))
               (not (string-contains? name "/")))
    (raise-pm-error 'config 'profile-activate "bad package name"
                    #:fields `(("name" . ,name)))))

;; string string -> void, rels stay inside their package dir
(define (check-entry-rel name rel)
  (define p (string->path rel))
  (when (or (absolute-path? p) (member 'up (explode-path p)))
    (raise-pm-error 'config 'profile-activate "rel escapes the package"
                    #:fields `(("package" . ,name) ("rel" . ,rel)))))

;; string path-string (listof string) -> (listof list), checked triples
(define (entry-triples name dir rels)
  (check-entry-name name)
  (unless (directory-exists? dir)
    (raise-pm-error 'activate 'profile-activate "package dir missing"
                    #:fields `(("package" . ,name)
                                ("dir" . ,(if (path? dir)
                                              (path->string dir)
                                              dir)))))
  (for/list ([rel (in-list rels)])
    (check-entry-rel name rel)
    (define target (build-path dir rel))
    (unless (or (file-exists? target) (directory-exists? target))
      (raise-pm-error 'activate 'profile-activate "activation target missing"
                      #:fields `(("package" . ,name) ("rel" . ,rel))))
    (list name (path->string target) rel)))

;; (listof entry) -> (listof list), every conflict fails before change
(define (check-conflicts triples)
  (define seen (make-hash))
  (for ([t (in-list triples)])
    (define rel (third t))
    (define prev (hash-ref seen rel #f))
    (cond [(not prev) (hash-set! seen rel t)]
          [(equal? (first prev) (first t)) (void)]
          [else
           (raise-pm-error
            'activate 'profile-activate "file conflict, nothing changed"
            #:fields `(("file" . ,rel)
                         ("owned-by" . ,(first prev))
                         ("claimed-by" . ,(first t)))
            #:hint "deactivate one package")])))

;; (listof entry) path-string -> void, one generation dir of links
(define (build-generation! triples gen)
  (define done (make-hash))
  (with-handlers ([exn:fail:filesystem?
                   (lambda (e)
                     (raise-pm-error 'activate 'profile-activate
                                     "cannot build generation"
                                     #:fields `(("dir" . ,(path->string gen)))
                                     #:cause e))])
    (for ([d (in-list '("bin" "lib" "include" "share" "libexec" "man"))])
      (make-directory* (build-path gen d)))
    (for ([t (in-list triples)])
      (define rel (third t))
      (unless (hash-ref done rel #f)
        (hash-set! done rel #t)
        (define link (build-path gen rel))
        (make-directory* (or (path-only link) gen))
        (make-file-or-directory-link (second t) link)))))

;; (listof entry) path-string -> path, validate all, then build + flip
(define (profile-activate entries profile-root)
  (when (null? entries)
    (raise-pm-error 'config 'profile-activate "nothing to activate"))
  (define triples (apply append (map (lambda (e) (apply entry-triples e))
                                     entries)))
  (check-conflicts triples)
  (make-directory* profile-root)
  (define gen (build-path profile-root
                          (gen-dir-name (next-gen-number profile-root))))
  (build-generation! triples gen)
  (swap-link! (path->string gen)
              (path->string (build-path profile-root "profile")))
  gen)

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/path
           "../core/errors.rkt")

  ;; All fixtures are synthetic (T-10) under one temp root: two fake
  ;; package trees plus a profile dir. Nothing touches the real home.
  (define test-root (build-path (find-system-path 'temp-dir)
                                "pm-activate-test"))
  (when (directory-exists? test-root)
    (delete-directory/files test-root))
  (define (pkgfile pkg . rels)
    (define p (apply build-path test-root pkg rels))
    (make-directory* (or (path-only p) test-root))
    (call-with-output-file p (lambda (out) (display "x" out))))
  (pkgfile "a" "bin" "prog")
  (pkgfile "a" "lib" "liba.a")
  (pkgfile "b" "bin" "other")
  (pkgfile "b" "share" "doc.txt")
  (pkgfile "c" "bin" "prog")
  (define prof (build-path test-root "profile"))
  (define (entry pkg)
    (list pkg
          (build-path test-root pkg)
          (map path->string
               (map (lambda (r) (apply build-path r))
                    (if (equal? pkg "a")
                        '(("bin" "prog") ("lib" "liba.a"))
                        (if (equal? pkg "b")
                            '(("bin" "other") ("share" "doc.txt"))
                            '(("bin" "prog"))))))))

  ;; Activate one package: generation 001 with resolving links, the
  ;; profile link flipped to it.
  (define gen1 (profile-activate (list (entry "a")) prof))
  (check-true (link-exists? (build-path gen1 "bin" "prog")))
  (check-equal? (path->string (resolve-path (build-path gen1 "bin" "prog")))
                (path->string (build-path test-root "a" "bin" "prog")))
  (check-equal? (path->string (resolve-path (build-path prof "profile")))
                (path->string gen1))

  ;; A second generation keeps the first and moves the profile link.
  (define gen2 (profile-activate (list (entry "a") (entry "b")) prof))
  (check-equal? (length (profile-generations prof)) 2)
  (check-equal? (path->string (resolve-path (build-path prof "profile")))
                (path->string gen2))
  (check-equal? (path->string (resolve-path (build-path gen2 "bin" "other")))
                (path->string (build-path test-root "b" "bin" "other")))

  ;; Two packages claiming one path fail closed with kind 'activate:
  ;; names the file, both sides, and changes nothing.
  (define before (resolve-path (build-path prof "profile")))
  (define conflict-err
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (profile-activate (list (entry "a") (entry "c")) prof)
      'no-error))
  (check-pred activate-error? conflict-err)
  (check-regexp-match #rx"file conflict, nothing changed"
                      (exn-message conflict-err))
  (check-regexp-match #rx"owned-by: a" (exn-message conflict-err))
  (check-regexp-match #rx"claimed-by: c" (exn-message conflict-err))
  (check-equal? (length (profile-generations prof)) 2)
  (check-equal? (resolve-path (build-path prof "profile")) before)

  ;; Empty activation, escaping rels and missing targets refuse.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-activate '() prof)
                'no-error))
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-activate (list (list "a" (build-path test-root "a")
                                              '("../x")))
                                  prof)
                'no-error))
  (check-pred activate-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (profile-activate (list (list "a" (build-path test-root "a")
                                              '("bin" "gone")))
                                  prof)
                'no-error))
  (delete-directory/files test-root))
