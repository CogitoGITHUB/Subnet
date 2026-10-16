#lang racket/base
;; security.rkt -- the policy, pure (S-01, D-037). One place that
;; answers "may pm do this?", with no I/O so it can be reasoned about
;; and tested exhaustively. No other module may answer a security
;; question: choke points call these predicates and refuse on #f.
;;
;; Seven named rules. Each predicate is total (never raises) over its
;; contract; refusal with a message is the caller's job (S-02), so the
;; policy stays testable without fixtures.

(require racket/contract/base
         racket/string
         "../errors/error-type.rkt"
         "../git/git-commit.rkt")

(provide
 (contract-out
  ;; any -> boolean, an exact pinned commit, never a ref that can move
  [commit-pinned? (-> any/c boolean?)]
  ;; any -> boolean, nothing requested means nothing pinned
  [source-pinned? (-> any/c boolean?)]
  ;; string boolean -> boolean, file:// only with the test escape
  [origin-allowed? (-> string? boolean? boolean?)]
  ;; path-string path-string -> boolean, target stays under prefix
  [path-contained? (-> path-string? path-string? boolean?)]
  ;; string string boolean -> boolean, resolved target inside and exists
  [symlink-target-ok? (-> string? string? boolean? boolean?)]
  ;; any -> boolean, only 755 and 644 are ever written
  [install-mode-allowed? (-> any/c boolean?)]
  ;; string -> boolean, no password in the URL
  [credential-safe? (-> string? boolean?)]
  ;; any -> boolean, the commands that change the machine
  [state-changing? (-> any/c boolean?)]

  ;; the four confirmation refusals, in one total predicate
  [confirmation-refusal (-> boolean? boolean? boolean? boolean?
                            (or/c string? #f))]))

;; ---------------------------------------------------------------------------
;; 1. Source trust. A git source is pinned to an exact commit id,
;; never a branch, a tag or "latest". The 40-or-64-hex shape is
;; git-id.rkt's format answer; PINNED here means present and shaped.

;; any -> boolean
(define (commit-pinned? v)
  (and (string? v) (git-id? v) #t))

;; any -> boolean, #f refuses: nothing requested pins nothing
(define (source-pinned? pin)
  (and pin (commit-pinned? pin) #t))

;; ---------------------------------------------------------------------------
;; 2. Origin. pm fetches over the network or not at all. file:// and
;; plain paths exist only so TEST fixtures work, and only when the
;; caller says test? explicitly: there is no environment sniffing
;; here, so a forgotten variable cannot open the hole (DEFAULT D-037).

;; string boolean -> boolean
(define (origin-allowed? url test?)
  (and (string? url)
       (not (string=? url ""))
       (or test?
           (and (not (string-prefix? url "file://"))
                (not (string-prefix? url "/"))
                (not (string-prefix? url "./"))
                (not (string-prefix? url "../"))))
       #t))

;; ---------------------------------------------------------------------------
;; 3 and 4. Paths. Lexical containment is pure: both sides absolute
;; simplified text, target equal to the prefix or under it with a slash
;; boundary, so /prefix-evil never passes for /prefix. Symlink targets
;; arrive already resolved by the caller with an exists flag, because
;; resolution itself needs the filesystem and this module has none.

;; string string -> boolean
(define (path-contained? prefix-text target-text)
  ;; Path inputs coerce: callers like git's inside-root? pass resolved
  ;; paths, and refusing them for their type would invert the answer.
  (define pre (if (path? prefix-text) (path->string prefix-text) prefix-text))
  (define tgt (if (path? target-text) (path->string target-text) target-text))
  (and (string? pre)
       (string? tgt)
       (or (string=? tgt pre)
           (string-prefix? tgt (string-append pre "/")))
       #t))

;; string string boolean -> boolean
(define (symlink-target-ok? prefix-text resolved-text exists?)
  (and exists?
       (path-contained? prefix-text resolved-text)
       #t))

;; ---------------------------------------------------------------------------
;; 5. Install mode. The only modes pm ever writes are 755 for
;; bin/libexec and 644 for everything else. A requested mode outside
;; those two refuses rather than being widened or narrowed.

;; any -> boolean
(define (install-mode-allowed? mode)
  (and (exact-integer? mode)
       (or (= mode #o755) (= mode #o644))
       #t))

;; ---------------------------------------------------------------------------
;; 6. Credentials. One redaction path (trace-redact in log.rkt) runs
;; before any destination; this predicate is its gate test: a URL
;; carrying user:password refuses before it can reach a message.

;; string -> boolean
(define (credential-safe? s)
  (and (string? s)
       (not (regexp-match? #rx"://[^/:@ \t]+:[^/@ \t]+@" s))
       #t))

;; ---------------------------------------------------------------------------
;; 7. Confirmation. These commands change the machine and need the
;; human token at every interface; approval at one layer is never
;; authorisation in pm. The token comparison itself lives with the
;; session (MCP) or the asker (OpenCode); this names the set.

;; any -> boolean
(define (state-changing? cmd)
  (define name (if (symbol? cmd) (symbol->string cmd) cmd))
  (and (string? name)
       (if (member name '("fetch" "apply" "update" "activate"
                          "rollback" "remove" "hold"))
           #t
           #f)))

;; ---------------------------------------------------------------------------
;; 8. The confirmation itself. There are FOUR ways to be refused and each
;; one gets its OWN name, because a caller that cannot tell "you sent
;; nothing" from "you sent the wrong secret" from "that secret already
;; spent itself" from "that secret approved a different plan" cannot act
;; on any of them. #f means: the token may be spent NOW.
;;
;; Pure, and it stays pure: the caller owns the state and passes the four
;; facts in, so the CLI and the MCP server ask this one predicate the same
;; question and cannot drift apart. No clock and no timer (D-015): a
;; token dies by USE or by session end, never by the wall clock.
;;
;; boolean? given?     the caller supplied a token at all
;; boolean? correct?   it is this session's token
;; boolean? spent?     it already approved one call
;; boolean? same-plan? it was issued for THIS plan
;; -> (or/c string? #f) the refusal name, or #f to allow

(define (confirmation-refusal given? correct? spent? same-plan?)
  (cond
    [(not given?)     "needs a confirmation token"]
    [(not correct?)   "wrong confirmation token"]
    [spent?           "confirmation token already used"]
    [(not same-plan?) "confirmation token is for a different plan"]
    [else             #f]))

;; ---------------------------------------------------------------------------
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
