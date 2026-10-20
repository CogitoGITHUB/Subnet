#lang racket/base
;; One job: the capability declaration — the tools the kit exposes, as
;; data. Registered in plan/package-tree.org; lands with TODO item 15.
;;
;; The declaration is DATA: the names, whether each one changes the
;; tree, and what it does. The MCP server reads it, the skill file is
;; written from it, and the gate fails when the declaration and the
;; surfaces disagree — a tool the declaration does not name does not
;; exist, and a name the declaration names but the program does not have
;; is a lie in the register.
;;
;; The mutating flag is not taken on trust: the engine checks it
;; against the security predicate before it runs anything (rule 07).
;;
;; Registered in plan/package-tree.org; lands with TODO item 15.

(require racket/list
         racket/string
         "../security/security.rkt")

;; capability is one tool: its name, whether it changes the tree, and
;; what it does.
(struct capability (name mutating description) #:transparent)

;; the-capabilities is the declaration: every tool of the kit, one line
;; each, in a fixed order.
(define the-capabilities
  (list (capability "routes" #f "walk the routing: every key, every layer")
        (capability "keys" #f "list the keys and what each one means")
        (capability "tasks" #f "list the task table")
        (capability "dashboard" #f "show the dashboard and every piece of it")
        (capability "agent" #f "show the agent's state and its pins")
        (capability "audit" #f "show the audit: what changed, and who changed it")
        (capability "task" #t "run one task of the task table")
        (capability "bake" #t "bake the meaning side into the hot path")
        (capability "send" #t "send the bundle to the agent")
        (capability "checkpoint" #t "make a checkpoint of the tree")
        (capability "rollback" #t "put the tree back at a checkpoint")
        (capability "stop" #t "throw or clear the stop switch")
        (capability "permit" #t "answer a permission ask")
        (capability "agent-end" #t "end the agent's session")
        (capability "audit-accept" #t "accept a change of the audit")
        (capability "audit-undo" #t "undo a change of the audit")
        (capability "plugin" #f "show the plugins the editor knows, and what pm says")
        (capability "plugin-register" #t "register a plugin from its manifest")
        (capability "plugin-install" #t "ask pm to install a plugin")
        (capability "plugin-call" #t "call one seam call on one plugin")))

;; capability-names answers the names in the declaration, in a fixed
;; order.
(define (capability-names)
  (sort (map capability-name the-capabilities) string<?))

;; capability-of answers the capability of a name, or nothing when the
;; declaration does not hold it.
(define (capability-of name)
  (for/or ([cap (in-list the-capabilities)])
    (and (string=? (capability-name cap) name) cap)))

;; declaration-agrees? answers whether the declaration and the security
;; predicate agree about one tool: the engine's own re-check of what
;; the kit says it does.
(define (declaration-agrees? name)
  (define cap (capability-of name))
  (and cap (eq? (state-changing? name) (capability-mutating cap))))

;; declaration-honest? answers whether the declaration agrees with the
;; security predicate about the tool: the engine's own re-check of what
;; the kit says it does. It answers the tool whose name disagrees, so a
;; reader is told WHICH tool lies.
(define (declaration-honest?)
  (for/first ([cap (in-list the-capabilities)]
               #:unless (eq? (state-changing? (capability-name cap))
                             (capability-mutating cap)))
    (capability-name cap)))

;; The declaration, for the surfaces above it.
(provide capability
         capability-name
         capability-mutating
         capability-description
         the-capabilities
         capability-names
         capability-of
         declaration-agrees?
         declaration-honest?)
