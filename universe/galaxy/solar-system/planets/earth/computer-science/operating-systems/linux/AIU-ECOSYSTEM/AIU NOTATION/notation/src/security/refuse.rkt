#lang racket/base
;; One job: the one door that turns a rule and an offending value into the
;; refusal every reader sees.
;; Lands with TODO item 1 (the tree lands).
;;
;; The refusal is an error record from ../errors/raise.rkt and nothing else:
;; who is this area, where is this file, and what is one sentence naming the
;; rule id, the value, what the rule refuses, and what the reader may do. A
;; refusal answers the CLI with exit code 2 (entry/dispatch.rkt), so a reader
;; who sees 2 knows a rule stopped the run and not that a document held a
;; finding. Nothing here prints: errors/render.rkt is the only printer.
;;
;; No caller yet. literate/targets.rkt and generation/write.rkt still raise
;; their own refusals, and rewiring them is a change in those areas and the
;; owner's. This door exists so that the change is one line per door when it
;; comes, and so that no second shape of refusal can grow beside it.

(require "../errors/raise.rkt"
         "security.rkt")

(provide refuse)


;; refuse raises the one refusal shape, and answers nothing. It takes a rule and
;; not an id — a caller looks the id up in security.rkt, so a rule that does not
;; exist is caught there and not printed as a broken message here. The rule id
;; is named in the text so a reader can match the line on the screen with the
;; rule in INDEX.org.
(define (refuse rule value)
  (raise-err 'security "refuse.rkt"
             (format "rule ~a refuses \"~a\": ~a; ~a"
                     (security-rule-id rule)
                     value
                     (security-rule-refuses rule)
                     (security-rule-remedy rule))))
