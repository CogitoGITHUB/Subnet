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
(define (check-git-url url)
  (define problem (url-problem url))
  (when problem
    (raise-pm-error 'spec 'check-git-url "rejected git URL"
                    #:fields `(("url" . ,url) ("reason" . ,problem)))))

;; ---------------------------------------------------------------------------
;; Allowlist (D-006 git only, D-011 vault promise)

;; string -> (or/c string? #f), reason or #f when allowed
(define (url-problem url)
  (cond [(string=? url "") "empty URL"]
        [(regexp-match? #rx"[ \t\n]" url) "whitespace in URL"]
        [(string-prefix? url "-") "starts with - (option injection)"]
        [(regexp-match? #rx"^[a-zA-Z0-9+.-]*::" url)
         "double-colon transports (like ext::) not allowed"]
        [(string-prefix? url "https://") (authority-problem url "https://")]
        [(string-prefix? url "ssh://") (authority-problem url "ssh://")]
        [(string-prefix? url "file://")
         ;; S-01: the test escape is explicit, never environmental.
         (if (origin-allowed? url (current-allow-file-urls))
             #f
             "file URLs are test-only")]
        [(regexp-match? #rx"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:" url) #f]
        [(regexp-match? #rx"^[a-zA-Z][a-zA-Z0-9+.-]*://" url)
         "scheme not allowed (https, ssh, scp-like, or test file only)"]
        [else "unrecognized URL shape"]))

;; string string -> (or/c string? #f), password check on the authority.
;; S-01: the shape of "has a password" is the policy's question.
(define (authority-problem url scheme-prefix)
  (if (credential-safe? url)
      #f
      "embedded password in URL (S-8)"))

;; ---------------------------------------------------------------------------
