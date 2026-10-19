#lang racket/base
;; security.rkt -- the policy, pure (S-01, D-037). One place that
;; answers "may pm do this?", with no I/O so it can be reasoned about
;; and tested exhaustively. No other module may answer a security
;; question: choke points call these predicates and refuse on #f.
;;
;; Seven named rules. Each predicate is total (never raises) over its
;; contract; refusal with a message is the caller's job (S-02), so the
;; policy stays testable without fixtures.
;;
;; Section 9 holds the SAME rules as DATA: every rule has an id, and a
;; refusal cites that id instead of typing a name of its own, so a user
;; can look the name up and two copies of one policy cannot drift.

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
                            (or/c string? #f))])

   ;; section 9: the rule as data. struct-out brings the three accessors,
  ;; so a reader (a test, a doc, the MCP server) can ask a rule what it
  ;; stands for; rule-set is the whole list, in predicate order. The nine
  ;; constants are DATA, not predicates, so they are provided plain: a
  ;; raise site cites one and nothing has to call it.
 (struct-out security-rule)
 rule-set
 ;; string -> (or/c security-rule? #f). Total, so provided plain.
 rule-by-id
 rule-commit-pinned
 rule-source-trust
 rule-origin
 rule-path-escape
 rule-symlink-target
 rule-install-mode
 rule-credential-safe
 rule-state-changing
 rule-readable-declaration)

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
;; 9. The named rule set, as DATA (S2-03).
;;
;; A refusal that names the mistake but not the RULE leaves the reader
;; hunting: "not a commit id" says what happened, "source-trust" says
;; which promise was broken and where the full rule is written down. So
;; every rule here is one value with three parts:
;;
;;   id          the kebab-case name a refusal cites and a user greps for.
;;               Spelled the way the refusal sites ALREADY spelled it
;;               ("[source-trust]", "[origin]", "[path-escape]",
;;               "[install-mode]"), so no message changes what it means.
;;   predicate   the policy predicate that answers this rule, or #f when
;;               the rule is a table the reader checks instead of a
;;               question one predicate answers.
;;   condition   the one sentence the rule stands for, so the data says
;;               what it is for and not only what it is called.
;;
;; One definition, no second copy: a raise site writes
;; (security-rule-id rule-install-mode), never the string it names. The
;; set is pure data, so a test can ask it the questions a user asks.

(struct security-rule (id predicate condition) #:transparent)

(define rule-commit-pinned
  (security-rule
   "commit-pinned" 'commit-pinned?
   "a git source pins one exact commit id, never a ref that can move"))

(define rule-source-trust
  (security-rule
   "source-trust" 'source-pinned?
   "a declaration either pins an exact commit id or pins nothing at all"))

(define rule-origin
  (security-rule
   "origin" 'origin-allowed?
   "over the network or not at all; file:// only when the caller says test?"))

(define rule-path-escape
  (security-rule
   "path-escape" 'path-contained?
   "an install destination stays under the prefix: no absolute, no .."))

(define rule-symlink-target
  (security-rule
   "symlink-target" 'symlink-target-ok?
   "a symlink resolves inside the prefix and its target exists"))

(define rule-install-mode
  (security-rule
   "install-mode" 'install-mode-allowed?
   "pm writes only 755 for bin and libexec and 644 for everything else"))

(define rule-credential-safe
  (security-rule
   "credential-safe" 'credential-safe?
   "no user:password in a URL, before any destination can see it"))

(define rule-state-changing
  (security-rule
   "state-changing" 'state-changing?
   "the commands that change the machine need the human token"))

;; The one rule with no predicate behind it. A declaration is a FILE pm
;; reads as data (D-014), and exactly one (spec ...) form lives in it, so
;; an unreadable file, an empty file and a file with a second top-level
;; form all break THIS rule and refuse by its name.
(define rule-readable-declaration
  (security-rule
   "readable-declaration" #f
   "a declaration is one file pm reads as data, holding one (spec ...) form"))

;; Every rule above, in predicate order. The list exists so the set can be
;; counted and checked as one thing; a raise site cites a member.
(define rule-set
  (list rule-commit-pinned
        rule-source-trust
        rule-origin
        rule-path-escape
        rule-symlink-target
        rule-install-mode
        rule-credential-safe
        rule-state-changing
        rule-readable-declaration))

;; string -> (or/c security-rule? #f), or #f when no rule carries that id.
;; WHY this exists: a refusal goes out carrying the id alone ("origin"),
;; because that is what fits in a message line and what a user greps for.
;; The reader who has that id and wants the whole rule -- what it stands
;; for, which predicate answers it, where it is enforced -- asks here, so
;; id -> rule is one lookup in one place instead of a switch each reader
;; writes. Pure: the answer comes from rule-set, never from a module that
;; might have loaded a different policy.
(define (rule-by-id id)
  (findf (lambda (r) (string=? (security-rule-id r) id)) rule-set))

;; ---------------------------------------------------------------------------
