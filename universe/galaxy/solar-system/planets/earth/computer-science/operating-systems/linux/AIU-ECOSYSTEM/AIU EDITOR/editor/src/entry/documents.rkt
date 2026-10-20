#lang racket/base
;; One job: the one JSON envelope — the shape every surface answers in.
;; Registered in plan/package-tree.org; lands with TODO item 15.
;;
;; The CLI, the MCP server, the skill and the plugin all answer in this
;; shape: the same fields, the same names, the same order. One shape
;; means an agent reads a CLI answer and an MCP answer the same way,
;; and it means the gate can check that they really are one shape.
;;
;; The envelope carries: who answers (the program), the version of the
;; shape, what kind of answer it is, whether it is an answer or a
;; refusal, the data, the refusal, and the events that came with it.
;;
;; A refusal names the rule it refused by: a reader must never have to
;; guess why a call did nothing.
;;
;; Registered in plan/package-tree.org; lands with TODO item 15.

(require json
         racket/list
         racket/string)

;; exit-ok is the code of an answer: the program answered, and the
;; answer is an answer.
(define exit-ok 0)

;; exit-refusal is the code of a refusal: the program refused, and it
;; named the rule it refused by.
(define exit-refusal 2)

;; exit-cannot-run is the code of a program that could not answer at
;; all: the tool did not run, and nothing was refused.
(define exit-cannot-run 3)

;; program-name is the program that answers.
(define program-name "aiu-editor")

;; envelope-version is the version of the shape. It rides the contract
;; version.
(define envelope-version "1")

;; document is the envelope: the kind of answer, whether it is an
;; answer, the data, the refusal and the events.
(struct document (kind ok data refusal events) #:transparent)

;; make-document answers an envelope. A refusal carries the rule it
;; refused by, and a refusal is never silent: the refusal is always in
;; the envelope.
(define (make-document kind ok data refusal events)
  (document kind ok data refusal events))

;; refusal-document answers the envelope of a refusal: the rule is named
;; in it, so a reader knows which rule stopped the call.
(define (refusal-document kind rule message)
  (make-document kind #f #f (hash 'rule rule 'message message) '()))

;; document-json answers the envelope as a hash, so it can be written as
;; JSON: the same field names, the same order, every time.
(define (document-json doc)
  (hash 'program program-name
        'version envelope-version
        'kind (document-kind doc)
        'ok (and (document-ok doc) #t)
        'data (or (document-data doc) '())
        'refusal (or (document-refusal doc) '())
        'events (or (document-events doc) '())))

;; document-line answers the envelope as one line of JSON: the shape
;; every surface sends.
(define (document-line doc)
  (define out (open-output-string))
  (write-json (document-json doc) out)
  (get-output-string out))

;; The envelope, for the surfaces above it.
(provide exit-ok
         exit-refusal
         exit-cannot-run
         program-name
         envelope-version
         document
         document-kind
         document-ok
         document-data
         document-refusal
         document-events
         make-document
         refusal-document
         document-json
         document-line)
