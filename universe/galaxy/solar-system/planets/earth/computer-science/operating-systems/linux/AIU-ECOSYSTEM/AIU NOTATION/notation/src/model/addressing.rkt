#lang racket/base
;; One job: how a send names a node (contract step 9).
;; Registered in plan/package-tree.org (model/addressing.rkt). Lands with TODO
;; item 3.
;;
;; The contract says it in one sentence
;; (contract/node-addressing-and-comments.org:13-15):
;;   "Address: names a node by kind and position — title, paragraph, code block,
;;    chunk — computed, never authored; stable while the document is edited
;;    elsewhere; readable by the owner and by an agent alike."
;;
;; So an address here is computed from a node's kind and position and nothing
;; else. There is no way to write one by hand, and a node that carries an
;; authored id has no address from this file. That last part is the open
;; contract question in ROOT-REQUEST-D014.org: an authored id is a different
;; thing, and this file does not invent it.

(require "nodes.rkt")

;; address-of builds the address of one node: its kind, its name and its
;; 1-based line. Nothing else goes into it.
(define (address-of n)
  (cond
    [(block-node? n)
     (format "~a:~a@~a" (block-node-name n) (block-node-name n) (block-node-line n))]
    [(error-node? n)
     (format "error:~a@~a" (error-node-kind n) (error-node-line n))]
    [else
     ;; A node kind this address does not know is refused, not guessed.
     (error 'addressing "a node that is neither a block nor an error has no address")]))

;; address-of-at builds the address of the node on a 1-based line.
(define (address-of-at nodes line)
  (define found (filter (lambda (n) (= (node-line n) line)) nodes))
  (cond
    [(null? found) #f]
    [(null? (cdr found)) (address-of (car found))]
    [else
     ;; Two nodes on one line is not something this file invents an address
     ;; for; it says so instead.
     (error 'addressing (format "~a nodes share line ~a; no single address" (length found) line))]))

;; addresses lists the address of every node, in tree order.
(define (addresses nodes)
  (map address-of nodes))