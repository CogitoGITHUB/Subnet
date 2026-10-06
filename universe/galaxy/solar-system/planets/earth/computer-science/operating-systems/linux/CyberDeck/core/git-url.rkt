#lang racket/base
;; git-url.rkt -- git URL validation (pure). Called at spec-read time
;; (file:line:col errors) AND again at the backend boundary (S-1).

(require racket/contract/base
         racket/string
         racket/list
         "errors.rkt")

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
         (if (current-allow-file-urls) #f "file URLs are test-only")]
        [(regexp-match? #rx"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:" url) #f]
        [(regexp-match? #rx"^[a-zA-Z][a-zA-Z0-9+.-]*://" url)
         "scheme not allowed (https, ssh, scp-like, or test file only)"]
        [else "unrecognized URL shape"]))

;; string string -> (or/c string? #f), password check on the authority
(define (authority-problem url scheme-prefix)
  (define rest (substring url (string-length scheme-prefix)))
  (define auth (car (string-split rest "/")))
  (define parts (string-split auth "@"))
  (if (and (> (length parts) 1)
           (regexp-match? #rx":" (string-join (drop-right parts 1) "@")))
      "embedded password in URL (S-8)"
      #f))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit)

  ;; Allowed shapes pass silently.
  (for ([url (in-list '("https://example.org/x.git"
                        "https://user@example.org/x.git"
                        "ssh://git@example.org/x.git"
                        "user@example.org:path/to/x.git"))])
    (check-not-exn (lambda () (check-git-url url))))
  (check-exn exn:fail:pm? (lambda () (check-git-url "")))

  ;; file:// needs the test flag.
  (check-exn exn:fail:pm?
             (lambda () (check-git-url "file:///tmp/x.git")))
  (parameterize ([current-allow-file-urls #t])
    (check-not-exn (lambda () (check-git-url "file:///tmp/x.git"))))

  ;; Rejections carry the url and the reason, kind 'spec.
  (define (reason-for url)
    (with-handlers ([exn:fail:pm?
                     (lambda (e) (cdr (assoc "reason" (exn:fail:pm-fields e))))])
      (check-git-url url)
      #f))
  (check-equal? (reason-for "ext::evil-command") "double-colon transports (like ext::) not allowed")
  (check-equal? (reason-for "--upload-pack=evil") "starts with - (option injection)")
  (check-equal? (reason-for "https://user:pass@example.org/x.git") "embedded password in URL (S-8)")
  (check-equal? (reason-for "ftp://example.org/x")
                  "scheme not allowed (https, ssh, scp-like, or test file only)")
  (check-pred spec-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (check-git-url "ext::sh -c true"))))
