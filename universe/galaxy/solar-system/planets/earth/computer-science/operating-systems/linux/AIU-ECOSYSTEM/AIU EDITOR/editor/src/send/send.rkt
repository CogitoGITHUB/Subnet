#lang racket/base
;; One job: the one action — build a bundle and call the boundary. There
;; is NO agent-specific code here (rule 08): the agent is named, and the
;; adapter behind the boundary does the rest.
;;
;; The send area is ABOVE the commands area, so the commands may not
;; reach up to it. The send area wires itself into the command table when
;; it loads, and the entry loads it, so the key finds the real command.
;;
;; A send makes a CHECKPOINT FIRST, so no bundle ever leaves without one:
;; the tree is put back to that checkpoint if the agent does something the
;; human did not want.
;;
;; The send answers the whole truth of the send: the bundle as it went,
;; what the agent said, the events that came back, and the permission
;; asks that are still waiting for the human. The approval is never
;; inferred (rule 07).
;;
;; Registered in plan/package-tree.org; lands with TODO item 9.

(require racket/file
         racket/list
         racket/path
         racket/string
         "../checkpoint/checkpoint.rkt"
         "../commands/commands.rkt"
         "adapter.rkt"
         "bundle.rkt"
         "opencode-adapter.rkt")

;; send-command is the command the key runs: it builds the bundle from
;; the session and asks the boundary to deliver it. The why is the words
;; after the command, and the target is the first of them.
(define (send-command session words)
  (define target (if (null? words) "opencode" (car words)))
  (define why (if (null? words) "" (string-join (cdr words) " ")))
  (cond
    [(not (agent-known? target))
     (cons #t (format "the send was refused: there is no adapter for the agent named ~a — the only adapter is opencode" target))]
    [else
     (define the-bundle
       (make-bundle "aiu-editor" "aiu-ecosystem" target
                    (selection-text session)
                    (path->string (session-file session))
                    (the-point session)
                    #f
                    why))
     (if (not the-bundle)
         (cons #t "a send needs a why: say what the sender was doing")
         (send-bundle session the-bundle))]))

;; agent-known? answers whether there is an adapter for the named agent.
;; The target is named, never inferred, and an agent without an adapter
;; is refused by name.
(define (agent-known? target)
  (string=? target "opencode"))

;; send-bundle makes the checkpoint, delivers the bundle and answers the
;; whole truth of the send. The checkpoint comes first: no bundle ever
;; leaves the program without one.
(define (send-bundle session the-bundle)
  (define tree (tree-root (session-file session)))
  (define made (checkpoint tree (bundle-why the-bundle)))
  (define client (client-from-environment))
  (define-values (handle attach-refusal) (attach client))
  (define feed (subscribe client))
  (if (not made)
      (cons #t "the send was refused: the tree could not be checkpointed, so nothing was sent")
      (if (not handle)
          (cons #t (format "the send was refused: ~a" (refusal-text attach-refusal)))
          (if (not feed)
              (cons #t "the send was refused: the event feed did not open, so nothing was sent")
              (let-values ([(message refusal) (deliver client handle the-bundle)])
                (if (not message)
                    (cons #t (format "the send was refused: ~a" (refusal-text refusal)))
                    (cons #t (string-join (send-answer client handle feed the-bundle made) "\n"))))))))

;; send-answer answers the whole truth of a send: the bundle as it went,
;; what the agent said, the events that came back, and the permission
;; asks that wait for the human.
(define (send-answer client handle feed the-bundle made)
  (define-values (the-events the-text refusal) (events client handle feed))
  (append
   (list (format "sent to ~a (the checkpoint is ~a)" (bundle-target the-bundle) made))
   (list "the bundle:")
   (bundle-lines the-bundle)
   (if (string=? the-text "")
       '()
       (list "the agent said:" the-text))
   (for/list ([event (in-list the-events)])
     (format "event: ~a" (hash-ref event 'type "unknown")))
   (let ([asks (client-permissions client handle)])
     (if (null? asks)
         '()
         (append
          (list "the agent asks for a permission:")
          (for/list ([ask (in-list asks)])
            (format "ask: ~a  action: ~a  files: ~a  answer with: permit once|always|reject ~a"
                    (hash-ref ask 'id "unknown")
                    (hash-ref ask 'action "unknown")
                    (string-join (ask-files ask) " ")
                    (hash-ref ask 'id "unknown"))))))))

;; refusal-text answers the text of a refusal: what could not be done,
;; and what to do about it.
(define (refusal-text refusal)
  (if (hash? refusal)
      (format "~a — ~a" (hash-ref refusal 'what "the agent refused the call")
              (hash-ref refusal 'what_to_do "the agent boundary is the one way to reach one"))
      "the agent refused the call"))

;; The send area is ABOVE the commands area, so the commands may not reach
;; up to it. The send area wires itself into the command table when it
;; loads, and the entry loads it, so the key finds the real command.
;;
;; A send makes a CHECKPOINT FIRST, so no bundle ever leaves without one:
;; the tree is put back to that checkpoint if the agent does something the
;; human did not want.
(hash-set! commands "send" send-command)

;; The one action, for the entry above it.
(provide send-command
         agent-known?)
