#lang racket/base
;; security-test.rkt -- the moved-out test submodule of src/security/security.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            racket/string
            "../../src/errors/error-type.rkt"
            "../../src/git/git-commit.rkt"
         "../../src/security/security.rkt")

(module+ test
  (require rackunit)

  ;; 1. Pinned means exact 40 hex; short, uppercased, empty and
  ;; non-strings refuse. Absent pins nothing.
  (check-true (commit-pinned? (make-string 40 #\a)))
  (check-true (commit-pinned? (make-string 64 #\f)))
  (check-false (commit-pinned? "main"))
  (check-false (commit-pinned? "v1.0"))
  (check-false (commit-pinned? (make-string 39 #\a)))
  (check-false (commit-pinned? (string-upcase (make-string 40 #\a))))
  (check-false (commit-pinned? ""))
  (check-false (commit-pinned? #f))
  (check-false (commit-pinned? 42))
  (check-true (source-pinned? (make-string 40 #\b)))
  (check-false (source-pinned? #f))
  (check-false (source-pinned? "latest"))

  ;; 2. Network URLs pass; file:// and paths pass only with test? #t.
  (check-true (origin-allowed? "https://example.org/a.git" #f))
  (check-true (origin-allowed? "git@github.com:a/b.git" #f))
  (check-false (origin-allowed? "file:///tmp/x" #f))
  (check-false (origin-allowed? "/tmp/x" #f))
  (check-false (origin-allowed? "../x" #f))
  (check-false (origin-allowed? "" #f))
  (check-true (origin-allowed? "file:///tmp/x" #t))
  (check-true (origin-allowed? "/tmp/x" #t))

  ;; 3+4. Containment with a slash boundary; the evil-prefix attack
  ;; fails; symlinks need existence plus containment. Paths coerce.
  (check-true (path-contained? "/p" "/p/a/b"))
  (check-true (path-contained? "/p" "/p"))
  (check-true (path-contained? (string->path "/p") (string->path "/p/a")))
  (check-false (path-contained? "/p" "/p-evil/a"))
  (check-false (path-contained? "/p" "/q/a"))
  (check-false (path-contained? "/p" "rel/a"))
  (check-true (symlink-target-ok? "/p" "/p/a" #t))
  (check-false (symlink-target-ok? "/p" "/p/a" #f))
  (check-false (symlink-target-ok? "/p" "/q/a" #t))

  ;; 5. Only the two modes pass; 777 and strings refuse.
  (check-true (install-mode-allowed? #o755))
  (check-true (install-mode-allowed? #o644))
  (check-false (install-mode-allowed? #o777))
  (check-false (install-mode-allowed? #o600))
  (check-false (install-mode-allowed? "755"))
  (check-false (install-mode-allowed? #f))

  ;; 6. A password in the URL refuses; clean URLs pass.
  (check-true (credential-safe? "https://example.org/a.git"))
  (check-false (credential-safe? "https://user:s3cret@example.org/a.git"))
  (check-true (credential-safe? "https://user@example.org/a.git"))

  ;; 7. The seven state-changing commands, nothing else.
  (for ([c (in-list '("fetch" "apply" "update" "activate"
                      "rollback" "remove" "hold"))])
    (check-true (state-changing? c) c))
  (for ([c (in-list '("plan" "check" "lock" "why" "owner" "verify"
                      "status" "held" "outdated" "help" ""))])
    (check-false (state-changing? c) c)))

