#lang racket/base
;; One job: what a node is; identity; blocks and error nodes only.
;; Registered in plan/package-tree.org (model/nodes.rkt). Lands with TODO
;; item 3.
;;
;; There is no node kind for loose text (syntax/first-slice-freeze.org, rule
;; b). Text outside a block becomes a stray-text **error node** that keeps its
;; span, so the reader can find it and the text is never deleted.

(require "../errors/raise.rkt")

(provide node-line node-span node-depth node->document quote-field
         (struct-out block-node) (struct-out error-node))


;; A block node: a name, where it is, how deep it sits, what it declares, and
;; what is inside it.
;;
;; The end line is its own field and not guessed from the end offset, because
;; the frozen document shape (join/INDEX.org) carries both, and a reader that
;; had to derive one from the other would be reading a different shape.
;;
;; The depth is how many blocks are open above it. It is the field that lets a
;; reader put a child under its parent without counting anything.
;;
;; The struct is mutable because the reader builds the tree by filling it in:
;; a block's children and declarations are known only as the document is read.
(struct block-node (name line start end-line end depth declarations children)
  #:transparent
  #:mutable)

;; An error node: which error, where, and what the reader can do about it.
(struct error-node (kind line offset opener-line what what-to-do) #:transparent)

;; A declaration is a list of four: the keyword, its value, the line it is on
;; and the byte it starts at. It is a list and not a struct because
;; diagnostics/collect.rkt reads it that way, and one place should decide the
;; shape of a declaration.
;;
;; The keyword is a symbol, because the registered keyword names are symbols
;; and a reader must not match a name against a string.
;;
;; The value is the text itself, with the quotes taken off, so a value that
;; holds a quote is the value and not a quotation of the value.
(define (declaration-keyword d) (list-ref d 0))
;; declaration-value gives the value of a declaration, with the quotes
;; off.
(define (declaration-value d) (list-ref d 1))
;; declaration-line gives the line a declaration sits on.
(define (declaration-line d) (list-ref d 2))
;; declaration-offset gives the byte offset a declaration starts at.
(define (declaration-offset d) (list-ref d 3))

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

;; node-depth gives every node how deep it sits. An error carries no depth of
;; its own in the document, so it answers the depth of the block it was found
;; in, which is the block it belongs to.
(define (node-depth n)
  (if (block-node? n) (block-node-depth n) 0))

;; quote-field writes one field the way the frozen document shape writes it:
;; in double quotes, with a double quote inside written twice (join/INDEX.org,
;; "Quoting"). A field that is written this way reads back as the same text.
(define (quote-field text)
  (define out (open-output-string))
  (display "\"" out)
  (for ([c (in-string text)])
    (when (char=? c #\") (display "\"" out))
    (display c out))
  (display "\"" out)
  (get-output-string out))

;; node->document prints one node back as a parse-tree-document, with the
;; declarations that were written inside it and everything nested under it, so
;; the model can hand a document on without inventing a second shape.
(define (node->document n depth)
  (cond
    [(block-node? n)
     (string-append
      (format "node block ~a ~a ~a ~a ~a ~a~%"
              (block-node-name n)
              (block-node-line n)
              (block-node-start n)
              (block-node-end-line n)
              (block-node-end n)
              depth)
      (apply string-append
             (map declaration->document (block-node-declarations n)))
      (apply string-append
             (map (lambda (c) (node->document c (add1 depth)))
                  (block-node-children n))))]
    [(error-node? n)
     (format "error ~a ~a ~a ~a ~a ~a~%"
             (error-node-kind n)
             (error-node-line n)
             (error-node-offset n)
             (if (error-node-opener-line n) (error-node-opener-line n) 0)
             (quote-field (error-node-what n))
             (quote-field (error-node-what-to-do n)))]
    [else
     (raise-err 'nodes "nodes.rkt"
                (format "~a is not a node; the tree holds blocks and error nodes only" n))]))

;; declaration->document prints one declaration back as a document line.
(define (declaration->document d)
  (format "decl ~a ~a ~a ~a~%"
          (declaration-keyword d)
          (quote-field (declaration-value d))
          (declaration-line d)
          (declaration-offset d)))
