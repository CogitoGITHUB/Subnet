#lang racket/base
;; rule-name-test.rkt -- the named rule set as DATA (S2-03), checked from
;; OUTSIDE the module that defines it.
;;
;; A refusal that names the mistake but not the RULE leaves the reader
;; hunting, so every rule has one kebab-case id and a refusal cites that
;; id. These tests ask the questions a user asks: is every id spelled the
;; way it says, is any name used twice, does every id point at a
;; predicate this module really provides, and do the names still answer
;; like the predicates behind them.

(require rackunit
         racket/list
         racket/runtime-path
         "../../src/security/security.rkt")

;; security.rkt as an ABSOLUTE path, so section 3 can ask the module what it
;; EXPORTS. An import cannot answer that question: namespace-variable-value
;; sees no imported binding and reported all eight predicates missing. The
;; path is anchored with define-runtime-path because a relative string handed
;; to dynamic-require resolved against the wrong directory -- D-054's lesson.
(define-runtime-path security-module "../../src/security/security.rkt")

;; ---------------------------------------------------------------------------
;; 1. The nine names, exactly as a refusal site spells them.

(module+ test
  (check-equal? (security-rule-id rule-commit-pinned) "commit-pinned")
  (check-equal? (security-rule-id rule-source-trust) "source-trust")
  (check-equal? (security-rule-id rule-origin) "origin")
  (check-equal? (security-rule-id rule-path-escape) "path-escape")
  (check-equal? (security-rule-id rule-symlink-target) "symlink-target")
  (check-equal? (security-rule-id rule-install-mode) "install-mode")
  (check-equal? (security-rule-id rule-credential-safe) "credential-safe")
  (check-equal? (security-rule-id rule-state-changing) "state-changing")
  (check-equal? (security-rule-id rule-readable-declaration)
                "readable-declaration"))

;; ---------------------------------------------------------------------------
;; 2. One set, no gaps and no repeats. rule-set is the whole thing, so a
;;    rule added without landing in the list fails here.

(module+ test
  (define ids (map security-rule-id rule-set))
  (check-equal? (length rule-set) 9)
  (check-equal? (length ids) (length (remove-duplicates ids))
                "two rules may not share one name")
  (check-equal? (sort (remove-duplicates ids) string<?)
                (sort (list "commit-pinned" "source-trust" "origin"
                            "path-escape" "symlink-target" "install-mode"
                            "credential-safe" "state-changing"
                            "readable-declaration")
                      string<?))
  ;; kebab-case: lowercase letters, digits and single dashes, no spaces,
  ;; no leading or trailing dash. This is the spelling a user greps for.
  (for ([r (in-list rule-set)])
    (define id (security-rule-id r))
    (check-true (regexp-match? #rx"^[a-z][a-z0-9]*(-[a-z0-9]+)*$" id)
                (string-append id " is not kebab-case"))
    (check-true (> (string-length (security-rule-condition r)) 10)
                (string-append id " must say what it stands for"))))

;; ---------------------------------------------------------------------------
;; 3. The set and the predicates agree. A rule that names a predicate
;;    this module does not provide is a name nobody can enforce.

(module+ test
  (for ([r (in-list rule-set)])
    (define pred (security-rule-predicate r))
    (cond
      [(not pred)
       ;; The one rule enforced by the reader's table rather than by a
       ;; predicate: a declaration is a file of data holding one form.
       (check-equal? (security-rule-id r) "readable-declaration")]
      [else
       (check-true (regexp-match? #rx"\\?$" (symbol->string pred))
                   (string-append (symbol->string pred)
                                  " is named as a predicate"))
       ;; dynamic-require asks security.rkt whether it provides the name,
       ;; which is what a rule naming a predicate is claiming; the
       ;; fail-thunk answers #f so a name nobody provides fails the check
       ;; instead of the run.
       (check-true (procedure? (dynamic-require security-module pred
                                                   (lambda () #f)))
                   (string-append
                    (security-rule-id r)
                    " names a predicate security.rkt does not provide"))])))

;; ---------------------------------------------------------------------------
;; 4. The set still answers like the predicates. A name that survives a
;;    rule going soft is worse than no name: the refusal cites it, so the
;;    rule has to be the same rule.

(module+ test
  (check-equal? (security-rule-id rule-commit-pinned)
                (if (commit-pinned? (make-string 40 #\a)) "commit-pinned" #f)
                "commit-pinned names the predicate above it")
  (check-false (commit-pinned? "main")
               "the named rule is still refused when the rule refuses")
  (check-equal? (security-rule-id rule-install-mode)
                (if (install-mode-allowed? #o755) "install-mode" #f))
  (check-false (install-mode-allowed? #o777))
  (check-equal? (security-rule-id rule-origin)
                (if (origin-allowed? "https://example.org/a.git" #f)
                    "origin"
                    #f))
  (check-false (origin-allowed? "file:///tmp/x" #f)))
