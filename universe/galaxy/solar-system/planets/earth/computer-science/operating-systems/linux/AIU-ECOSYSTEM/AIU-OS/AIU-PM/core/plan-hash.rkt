#lang racket/base
;; plan-hash.rkt -- the sha1 hex of a string, the canonical text one
;; package-plan hashes over, and the two path shapes that hash feeds. It
;; must not derive or lower anything.

(require racket/string
         openssl/sha1
         "plan-actions.rkt"
         "spec.rkt"
         "version.rkt")

(provide
 ;; string -> string, sha1 hex of the full content
 string-sha1hex
 ;; package-plan -> string, the bytes the input hash covers
 package-plan-canonical
 ;; package-plan -> string, dedup identity: same plan twice lowers once
 package-plan-identity
 ;; package-plan -> string, store path below <state>/store (D-023)
 package-plan-store-dir)

;; ---------------------------------------------------------------------------
;; Hashing (sha1 over bytes, never equal-hash-code, which a runtime may
;; salt, so two runs of one input agree)

;; string -> string, sha1 hex of the full content (stable across runs)
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

;; package-plan -> string, dedup identity: same plan twice lowers once
(define (package-plan-identity pp)
  (string-append (symbol->string (package-plan-name pp))
                 "/"
                 (symbol->string (package-plan-slot pp))
                 "/"
                 (version->string (package-plan-version pp))
                 "/"
                 (package-plan-input-hash pp)))

;; package-plan -> string, store path below <state>/store (D-023):
;; name/slot/version-hash12; two slots plan to two dirs
(define (package-plan-store-dir pp)
  (string-append (symbol->string (package-plan-name pp))
                 "/"
                 (symbol->string (package-plan-slot pp))
                 "/"
                 (version->string (package-plan-version pp))
                 "-"
                 (substring (package-plan-input-hash pp) 0 12)))
