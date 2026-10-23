#lang racket/base
;; One job: the security predicates — what may happen without asking.
;; Registered in plan/package-tree.org; lands with TODO item 13.
;;
;; A predicate is TOTAL: it answers for every action name, and it never
;; guesses. An action it does not know is a refusal, not a yes: the
;; safe answer for an unknown action is that it changes the tree and
;; that it is not reversible.
;;
;; The predicates live in the SECURITY area, below the send area, because
;; the send area and the audit area ask them, and an area may only
;; reach DOWNWARD.
;;
;; Every definition in this area is called from OUTSIDE the area: the
;; gate's security stage fails when a rule protects nothing, because a
;; predicate nobody calls is a rule that is not there.
;;
;; Registered in plan/package-tree.org; lands with TODO item 13.

(require racket/string)

;; reading-actions are the actions that only read: they change nothing
;; in the tree.
(define reading-actions
  '("list" "show" "read" "open" "find" "where" "git" "journal" "help"
    "routes" "keys" "tasks" "dashboard" "agent" "audit" "plugin"))

;; changing-actions are the actions that change the tree. Everything
;; else — including an action nobody knows — is treated as changing.
(define changing-actions
  '("send" "new" "new-directory" "rename" "delete" "move" "copy"
    "paste" "cut" "undo" "accept" "agent-write"))

;; reversible-actions are the actions the journal can take back: the
;; tree goes back to the state before the action.
(define reversible-actions
  '("new" "new-directory" "rename" "move" "copy" "paste" "undo"))

;; state-changing? answers whether the action changes the tree. A known
;; read answers no; everything else answers yes, because an action
;; nobody knows is a state change until it is known.
(define (state-changing? action)
  (not (member action reading-actions)))

;; reversible? answers whether the action can be taken back. A delete
;; cannot: the bytes are gone, so it needs a confirmation and a copy.
(define (reversible? action)
  (if (member action reversible-actions) #t #f))

;; checkpoint-needed? answers whether the action needs a checkpoint
;; before it happens. Every action that changes the tree needs one: the
;; tree is put back to that checkpoint if the human did not want it.
(define (checkpoint-needed? action)
  (state-changing? action))

;; The predicates, for the areas above this one.
(provide state-changing?
         reversible?
         checkpoint-needed?)
