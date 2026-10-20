#lang racket/base
;; One job: the one action — build a bundle and call the boundary. There
;; is NO agent-specific code here (rule 08): the agent is named, and the
;; adapter behind the boundary does the rest.
;;
;; The send area is ABOVE the commands area, so the commands may not reach
;; up to it. The send area wires itself into the command table when it
;; loads, and the entry loads it, so the key finds the real command.
;;
;; Registered in plan/package-tree.org; lands with TODO item 9.

(require racket/list
         racket/string
         "../commands/commands.rkt"
         "adapter.rkt"
         "bundle.rkt")

;; send-command is the command the key runs: it builds the bundle from
;; the session and asks the adapter to deliver it. The why is the words
;; after the command, and the target is the first of them.
(define (send-command session words)
  (define target (if (null? words) "opencode" (car words)))
  (define why (if (null? words) "" (string-join (cdr words) " ")))
  (define the-bundle
    (make-bundle "aiu-editor" "aiu-ecosystem" target
                 (selection-text session)
                 (path->string (session-file session))
                 (the-point session)
                 #f
                 why))
  (if (not the-bundle)
      (cons #t "a send needs a why: say what the sender was doing")
      (let ([answer (deliver opencode-adapter the-bundle)])
        (if (car answer)
            (cons #t (format "sent to ~a" target))
            (cons #t (format "the send was refused: ~a — ~a"
                             (hash-ref (cdr answer) 'what)
                             (hash-ref (cdr answer) 'what_to_do)))))))

;; The send area is ABOVE the commands area, so the commands may not reach
;; up to it. The send area wires itself into the command table when it
;; loads, and the entry loads it, so the key finds the real command.
(hash-set! commands "send" send-command)

;; The one action, for the entry above it.
(provide send-command)
