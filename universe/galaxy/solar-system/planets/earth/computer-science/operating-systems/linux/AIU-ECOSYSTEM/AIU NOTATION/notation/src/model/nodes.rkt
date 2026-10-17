#lang racket/base
;; One job: what a node is; identity; blocks and error nodes only.
;; Registered in plan/package-tree.org (model/nodes.rkt). Lands with TODO
;; item 3.
;;
;; There is no node kind for loose text (syntax/first-slice-freeze.org, rule
;; b). Text outside a block becomes a stray-text **error node** that keeps its
;; span, so the reader can find it and the text is never deleted.

(require "../errors/raise.rkt")

;; A block node: a name, where it is, what it declares, and what is inside it.
(struct block-node (name line start end declarations children) #:transparent)

;; An error node: which error, where, and what the reader can do about it.
(struct error-node (kind line offset opener-line what what-to-do) #:transparent)

;; node-line gives every node its line, so a caller never asks a node what kind
;; it is just to find out where it is.
(define (node-line n)
  (cond
    [(block-node? n) (block-node-line n)]
    [(error-node? n) (error-node-line n)]
    [else 0]))

;; node-span gives every node the byte span it came from, which is what the
;; renderer cuts text out of.
(define (node-span n)
  (cond
    [(block-node? n) (cons (block-node-start n) (block-node-end n))]
    [(error-node? n) (cons (error-node-offset n) (error-node-offset n))]
    [else (cons 0 0)]))

;; node->document prints one node back as a parse-tree-document line, so the
;; model can hand a document on without inventing a second shape.
(define (node->document n depth)
  (cond
    [(block-node? n)
     (format "node block ~a ~a ~a ~a ~a ~a ~a~%"
             (block-node-name n)
             (block-node-line n)
             (block-node-start n)
             (block-node-end n)
             (block-node-end n)
             depth)]
    [(error-node? n)
     (format "error ~a ~a ~a ~a \"~a\" \"~a\"~%"
             (error-node-kind n)
             (error-node-line n)
             (error-node-offset n)
             (if (error-node-opener-line n) (error-node-opener-line n) 0)
             (error-node-what n)
             (error-node-what-to-do n))]
    [else
     (raise-err 'nodes "nodes.rkt"
                (format "~a is not a node; the tree holds blocks and error nodes only" n))]))