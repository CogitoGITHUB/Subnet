#lang racket/base
;; git-url.rkt -- git URL validation (pure). Called at spec-read time
;; (file:line:col errors) AND again at the backend boundary (S-1).

(require racket/contract/base
         racket/string
         racket/list
         "../errors/error-type.rkt"
         "../security/security.rkt")

(provide
 (contract-out
  ;; Tests may enable file:// URLs; production never does (default #f).
  [current-allow-file-urls (parameter/c boolean?)]
  ;; string -> void, raises kind 'spec outside the allowlist
  [check-git-url (-> string? void?)]))

;; ---------------------------------------------------------------------------
;; Configuration and entry point

(define current-allow-file-urls (make-parameter #f))

;; string -> void, raises kind 'spec outside the allowlist
;; The problem travels with the RULE that found it, so the refusal names
;; the promise it broke instead of only the shape it disliked.
(define (check-git-url url)
  (define problem (url-problem url))
  (when problem
    (raise-pm-error 'spec 'check-git-url "rejected git URL"
                    #:fields `(("url" . ,url)
                               ("reason" . ,(car problem)))
                    #:rule (cdr problem))))

;; ---------------------------------------------------------------------------
;; Allowlist (D-006 git only, D-011 vault promise)

;; string -> (or/c (cons string? security-rule?) #f)
;; WHY one value and not two: which rule matched and why are the same
;; decision, so a second lookup could drift from the first. Every shape
;; problem here is rule-origin -- the allowlist IS the origin rule, and
;; origin-allowed? refuses the same strings -- and an authority carrying a
;; password is rule-credential-safe, which is a different promise broken.
;; The reason strings stay exactly as they were.
(define (url-problem url)
  (cond [(string=? url "") (cons "empty URL" rule-origin)]
        [(regexp-match? #rx"[ \t\n]" url)
         (cons "whitespace in URL" rule-origin)]
        [(string-prefix? url "-")
         (cons "starts with - (option injection)" rule-origin)]
        [(regexp-match? #rx"^[a-zA-Z0-9+.-]*::" url)
         (cons "double-colon transports (like ext::) not allowed" rule-origin)]
        [(string-prefix? url "https://") (authority-problem url "https://")]
        [(string-prefix? url "ssh://") (authority-problem url "ssh://")]
        [(string-prefix? url "file://")
         ;; S-01: the test escape is explicit, never environmental.
         (if (origin-allowed? url (current-allow-file-urls))
             #f
             (cons "file URLs are test-only" rule-origin))]
        [(regexp-match? #rx"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:" url) #f]
        [(regexp-match? #rx"^[a-zA-Z][a-zA-Z0-9+.-]*://" url)
         (cons "scheme not allowed (https, ssh, scp-like, or test file only)"
               rule-origin)]
        [else (cons "unrecognized URL shape" rule-origin)]))

;; string string -> (or/c (cons string? security-rule?) #f), password check
;; on the authority. S-01: the shape of "has a password" is the policy's
;; question, and the rule it breaks is the credential one, not origin.
(define (authority-problem url scheme-prefix)
  (if (credential-safe? url)
      #f
      (cons "embedded password in URL (S-8)" rule-credential-safe)))

;; ---------------------------------------------------------------------------
