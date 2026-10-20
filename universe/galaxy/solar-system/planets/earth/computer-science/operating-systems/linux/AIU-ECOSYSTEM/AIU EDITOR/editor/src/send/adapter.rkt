#lang racket/base
;; One job: the adapter — the boundary one way. The calls are the
;; contract's (../contract/ai-link-boundary.org): open or attach a
;; session; send a bundle; subscribe to the session's events; answer a
;; permission ask; cancel; end. The adapter translates; nothing
;; agent-specific crosses the boundary.
;;
;; NO SILENT DOWNGRADE: what the agent cannot do today, the adapter
;; refuses BY NAME. The pins are reported too: the boundary version the
;; adapter implements and the agent version it was verified against.
;;
;; Registered in plan/package-tree.org; lands with TODO item 9.

(require racket/list
         racket/string
         "../machine/stop-switch.rkt"
         "bundle.rkt")

;; adapter is one agent behind the boundary: its name, the boundary
;; version it implements, the agent version it was verified against, and
;; whether it is attached right now.
(struct adapter (name boundary-version agent-version attached?) #:transparent)

;; opencode-adapter is the OpenCode adapter. It is not attached: nothing
;; has attached an agent yet, and the adapter says so by name rather than
;; pretending.
(define opencode-adapter
  (adapter "opencode" boundary-version "unverified" #f))

;; Every call answers a PAIR: the value, and the refusal — the refusal is
;; nothing when there is none, and a refusal is always named.
;;
;; attach opens or attaches a session to the agent and answers the
;; session handle, or the refusal by name when the agent is not there.
;; A handle outlives the caller's screen, like the holder's shells do.
(define (attach a)
  (if (adapter-attached? a)
      (cons (hash 'handle (format "~a-session" (adapter-name a)))
            #f)
      (cons #f (refusal a "the agent is not attached"))))

;; deliver sends a bundle to the agent and answers what came back. The
;; reply comes back as a file the editor can read.
;;
;; The stop switch is asked FIRST: while it is thrown, no bundle goes to
;; any agent session for this project (D-010).
(define (deliver a bundle)
  (cond
    [(stopped?)
     (cons #f (refusal a "the stop switch is thrown: every agent session for this project stops"))]
    [(and (adapter-attached? a) (bundle? bundle))
     (cons #f (refusal a "the agent takes no bundle yet"))]
    [else
     (cons #f (refusal a "the agent is not attached"))]))

;; events answers the events of a session, subscribed to. It is a list of
;; the one event record, enriched with the agent identity and the
;; session.
(define (events a session)
  (if (adapter-attached? a)
      (cons '() #f)
      (cons '() (refusal a "the agent is not attached"))))

;; answer-permission answers a permission ask in the human's own UI. The
;; approval is never inferred: the human says yes or no.
(define (answer-permission a ask)
  (if (adapter-attached? a)
      (cons (hash 'decision "refused" 'ask ask) #f)
      (cons #f (refusal a "the agent is not attached"))))

;; cancel cancels a session.
(define (cancel a session)
  (if (adapter-attached? a)
      (cons #f (refusal a "the agent has no session to cancel"))
      (cons #f (refusal a "the agent is not attached"))))

;; end ends a session.
(define (end-session a session)
  (if (adapter-attached? a)
      (cons #f (refusal a "the agent has no session to end"))
      (cons #f (refusal a "the agent is not attached"))))

;; pins answers the two pins: the boundary version the adapter
;; implements and the agent version it was verified against.
(define (pins a)
  (hash 'boundary (adapter-boundary-version a)
        'agent (adapter-agent-version a)))

;; refusal answers the refusal of an adapter: what it cannot do, and
;; what to do about it. The refusal names the agent and the rule.
(define (refusal a what)
  (hash 'kind "err-no-agent"
        'who (adapter-name a)
        'what what
        'what_to_do "attach an agent first: the agent boundary is the one way to reach one"))

;; The adapter, for the entry above it.
(provide adapter
         adapter-name
         adapter-boundary-version
         adapter-agent-version
         adapter-attached?
         opencode-adapter
         attach
         deliver
         events
         answer-permission
         cancel
         end-session
         pins
         refusal)
