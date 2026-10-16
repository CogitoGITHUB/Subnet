#lang racket/base
;; confirmation-test.rkt -- the confirmation gate, tested from OUTSIDE the
;; module that enforces it (audit findings 1 and 2).
;;
;; Every refusal is checked by NAME, because a caller that cannot tell
;; "you sent nothing" from "wrong secret" from "already spent" from
;; "wrong plan" cannot act on any of them. The happy path is checked too:
;; a gate that refuses everything passes every refusal test.
;;
;; The session struct is provided as struct-out, so spent? and the plan
;; binding can be set directly and the gate asked without spawning a tool
;; or touching the disk. That is the point: these are decisions, and a
;; decision test should not need a machine.

(require rackunit
         racket/list
         racket/port
         "../../src/security/security.rkt"
         "../../src/entry/mcp-server.rkt")

(define (fresh-session)
  (make-session (open-input-string "") (open-output-nowhere)))

;; the MCP arguments object, with the confirmation field this gate reads
(define (with-confirmation tok)
  (hasheq 'confirmation tok))

;; ---------------------------------------------------------------------------
;; 1. The token is a secret, not a constant. This is the finding: the old
;; token was the literal "pm-confirm-0001", published in the source.

(module+ test
  (define s1 (fresh-session))
  (define s2 (fresh-session))
  (define t1 (session-token s1))

  (check-not-equal? t1 "pm-confirm-0001"
                    "the token must not be a published constant")
  (check-equal? (string-length t1) 64
                "32 bytes hex-encoded is 64 characters")
  ;; pregexp has no {n} interval quantifier, so this is the length check
  ;; above plus a character-class check, not one clever regexp.
  (check-true (regexp-match? #rx"^[0-9a-f]+$" t1)
              "the token is lowercase hex and nothing else"))

;; 2. Every session gets its own secret.
(module+ test
  (define tokens
    (for/list ([i (in-range 5)])
      (session-token (fresh-session))))
  (check-equal? (length (remove-duplicates tokens)) 5
                "five sessions must not share a token"))

;; ---------------------------------------------------------------------------
;; 3. The four refusals, from the one shared predicate. Nothing here knows
;;    about MCP: this is the policy both surfaces ask.

(module+ test
  (check-equal? (confirmation-refusal #f #t #f #t) "needs a confirmation token")
  (check-equal? (confirmation-refusal #t #f #f #t) "wrong confirmation token")
  (check-equal? (confirmation-refusal #t #t #t #t) "confirmation token already used")
  (check-equal? (confirmation-refusal #t #t #f #f)
                "confirmation token is for a different plan")
  (check-equal? (confirmation-refusal #t #t #f #t) #f
                "all four true: the token may be spent")
  ;; Order matters: a wrong token that was also spent is still "wrong", and
  ;; a missing token never reports anything about plans.
  (check-equal? (confirmation-refusal #f #f #t #f) "needs a confirmation token")
  (check-equal? (confirmation-refusal #t #f #t #f) "wrong confirmation token"))

;; ---------------------------------------------------------------------------
;; 4. The gate as the MCP server actually asks it.

(module+ test
  (define s (fresh-session))
  (define argv '("demo.spec"))
  (define digest (plan-digest "apply" argv))
  (session-authorise! s digest)

  ;; absent: no confirmation key at all
  (check-equal? (confirmation-refusal-for "apply" argv s (hasheq))
                "needs a confirmation token")
  ;; wrong: a token that is not this session's
  (check-equal? (confirmation-refusal-for "apply" argv s
                                          (with-confirmation "nope"))
                "wrong confirmation token")
  ;; right token, right plan: allowed
  (check-equal? (confirmation-refusal-for "apply" argv s
                                          (with-confirmation (session-token s)))
                #f)
  ;; right token, WRONG plan: refused by its own name
  (check-equal? (confirmation-refusal-for "apply" '("other.spec") s
                                          (with-confirmation (session-token s)))
                "confirmation token is for a different plan")
  ;; single use: once spent, the same token buys nothing
  (set-mcp-session-spent! s #t)
  (check-equal? (confirmation-refusal-for "apply" argv s
                                          (with-confirmation (session-token s)))
                "confirmation token already used")
  ;; and a spent token cannot be re-bound to a fresh plan
  (check-exn #rx"already used"
             (lambda () (session-authorise! s (plan-digest "fetch" '("m.json"))))))

;; 5. The digest is stable for one call and different for another.
(module+ test
  (check-equal? (plan-digest "apply" '("a")) (plan-digest "apply" '("a")))
  (check-not-equal? (plan-digest "apply" '("a")) (plan-digest "apply" '("b")))
  (check-not-equal? (plan-digest "apply" '("a")) (plan-digest "fetch" '("a")))
  (check-equal? (session-plan-digest (fresh-session)) #f
                "a fresh session's token is bound to nothing yet"))

;; ---------------------------------------------------------------------------
;; 6. ONE named set, read by both surfaces. The CLI's gate and the MCP
;;    gate are deliberately different mechanisms (README and the decision
;;    in OPEN-DECISIONS say so), but the SET of commands that change
;;    machine state is named once, in security.rkt, and nobody keeps a
;;    second copy of it.

(module+ test
  (define gated '("fetch" "apply" "update" "activate" "rollback" "remove" "hold"))
  (for ([c gated]) (check-true (state-changing? c) c))
  (for ([c '("plan" "check" "lock" "why" "owner" "verify" "status" "held"
             "outdated" "help" "events.runs" "events.tail" "run.get")])
    (check-false (state-changing? c) c))
  ;; symbols are accepted too, so a caller cannot slip past with one
  (check-true (state-changing? 'fetch))
  (check-false (state-changing? 'plan))
  (check-false (state-changing? 42))
  (check-false (state-changing? #f))
  ;; the CLI's documented --confirm command is in that same set, so the two
  ;; surfaces cannot disagree about WHICH commands change the machine
  (check-true (state-changing? "apply")))
