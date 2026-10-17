#lang racket/base
;; profile-flip.rkt -- the profile actions: activate validates every
;; entry first, builds the next generation, then flips the profile
;; link with store.rkt's atomic swap (a conflict fails closed with
;; kind 'activate, exit 9, before anything changes); rollback repoints
;; at a numbered generation; remove builds a generation minus
;; one package and never touches store dirs (D-024). The writer lock
;; is a caller (CLI) concern per E-12c, not this module's.

(require racket/file
         racket/list
         racket/path
         racket/string
         "../store/store.rkt"
         "../errors/error-type.rkt"
         "../narration/narration.rkt"
         "generation.rkt")

(provide
 ;; the profile actions; contracts stay on the facade
 profile-activate
 profile-rollback
 profile-remove)

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

;; (listof entry) path-string -> path, validate all, then build + flip
(define (profile-activate entries profile-root
                             #:interface [interface "unknown"]
                             #:specs [specs '()]
                             #:lock [lock #f])
  (when (null? entries)
    (raise-pm-error 'config 'profile-activate "nothing to activate"))
  (define triples (apply append (map (lambda (e) (apply entry-triples e))
                                     entries)))
  (check-conflicts triples)
  (make-directory* profile-root)
  (define gen (build-path profile-root
                          (gen-dir-name (next-gen-number profile-root))))
  (build-generation! triples gen)
  ;; G-10: who and why. The run id is read off the active narration
  ;; run, so the event feed of that id reconstructs this decision; the
  ;; interface names who triggered it. Outside any run both are absent
  ;; rather than invented.
  (call-with-output-file (build-path gen "provenance.rktd")
    (lambda (out)
      (write `(provenance (,(current-run-id) ,interface ,specs ,lock)) out))
    #:exists 'truncate/replace)
  (swap-link! (path->string gen)
              (path->string (build-path profile-root "profile")))
  gen)

;; path-string exact-integer -> path, repoint at generation N
(define (profile-rollback profile-root n)
  (define gen (build-path profile-root (gen-dir-name n)))
  ;; D-036: a rollback is the same consequential move as an activate,
  ;; so it is narrated the same way, and the generation it repoints at is
  ;; named in the event rather than only in the message.
  (with-op 'rollback (gen-dir-name n)
           "the profile is repointed at an earlier generation"
           #:how (path->string (build-path profile-root "profile"))
           (lambda ()
             (unless (directory-exists? gen)
               (skip 'rollback (path->string gen)
                     "the named generation is not on disk")
               (raise-pm-error 'config 'profile-rollback "unknown generation"
                               #:fields `(("generation" . ,(gen-dir-name n)))))
             (step 'rollback "swap"
                   "the profile link flips back to the earlier generation")
             (swap-link! (path->string gen)
                         (path->string (build-path profile-root "profile")))
             gen)))

;; path-string string (listof entry) -> path, new generation minus one.
;; The package must be active now and gone from the survivors; store
;; dirs are never touched (D-024). Emptying the profile deletes the
;; link and returns the profile root.
(define (profile-remove profile-root name entries)
  (when (member name (map first entries))
    (raise-pm-error
      'config
      'profile-remove
      "package still present"
      #:fields `(("package" . ,name))
    )
  )
  (unless (member name (generation-owner-names (current-generation profile-root)))
    (raise-pm-error
      'config
      'profile-remove
      "package not active"
      #:fields `(("package" . ,name))
    )
  )
  ;; D-036: removing the last package DELETES the profile link rather
  ;; than swapping it, which is a different enough outcome to narrate.
  (if (null? entries)
    (begin
      (with-op 'remove (path->string profile-root)
               "the last package is gone, so the profile link is deleted"
               (lambda ()
                 (step 'remove "unlink"
                       "no generation remains, so there is nothing to point at")
                 (delete-file (build-path profile-root "profile"))
                 (if (path? profile-root)
                   profile-root
                   (string->path profile-root)))))
    (with-op 'remove (format "~a removed from ~a" name (path->string profile-root))
             "the profile is rebuilt without this package"
             #:inputs (list name)
             (lambda ()
               (step 'remove "rebuild"
                     "a new generation is built beside the old one; store dirs are untouched")
               (profile-activate entries profile-root))))
)
