#lang racket/base
;; git-env-test.rkt -- the moved-out test submodule of src/git/git-env.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            racket/string
            racket/list
            "../../src/errors/error-type.rkt"
            "../../src/security/security.rkt"
         "../../src/git/git-env.rkt")

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

