#lang racket/base
;; One job: the calls the editor and the multiplexer make, and the answers they
;; get back — with the node addresses those answers carry.
;; Registered in plan/package-tree.org (surface/surface.rkt). Lands with TODO
;; item 8 (build step 7, the engine surface).
;;
;; This is the door. A host opens a document, the tree is built on the meaning
;; side, and everything that leaves this file leaves as the text frozen in
;; answers.rkt. Nothing here calls back into the host, and nothing of the Rust
;; parser crosses: this file sees the tree Racket already built, and the only
;; thing a host ever receives is text.
;;
;; Addressing, which is the load-bearing part
;; -----------------------------------------
;; An address is a node's path from the root: the kind of every node above it,
;; then its own kind, each followed by its 1-based ordinal among the siblings
;; of that kind. A title first in a document is =title/1=; the second paragraph
;; inside it is =title/1/paragraph/2=. Ordinals are counted per kind, so a
;; paragraph added between two code blocks renumbers no code block.
;;
;; What makes it stable: the bytes of the document decide the address and
;; nothing else does. The same text gives the same addresses on every run, on
;; every machine, with no clock, no hash seed and no count of what happened
;; before — so an address the editor stored keeps naming the same node while
;; the owner edits anywhere else. Adding a line above a node shifts that
;; node's line number (the address in model/addressing.rkt is name and line,
;; and it shifts with it) and shifts this address not at all.
;;
;; What breaks it: inserting, removing or re-kindling a sibling of the SAME
;; kind above a node renumbers the ordinals below it, so a stored address then
;; names whatever node moved into that slot. That is the price of an address
;; computed and never authored (contract/node-addressing-and-comments.org,
;; lines 13-15), and it is a price worth naming rather than hiding: a node that
;; must keep its name across a reorder needs an authored id, which is the open
;; question in ROOT-REQUEST-D014.org. This file does not invent it. An address
;; that must outlive a reorder stays a path in this document and an identity in
;; the host.
;;
;; Narration: reading a tree in memory does not block, so the wait door stays
;; shut for the answers (diagnostics/collect.rkt says the same and is the
;; precedent). Writing one does block — a disk may be slow, full or gone — so
;; the write announces itself and why before it blocks and again when it is
;; through.

(require racket/file
         racket/list
         racket/path
         "../errors/raise.rkt"
         "../machine/directories.rkt"
         "../model/nodes.rkt"
         "../model/outline.rkt"
         "../narration/narration.rkt"
         "../narration/wait-door.rkt"
         "answers.rkt")

(provide surface-answers
         surface-document
         surface-node-at
         write-surface-document)


;; surface-answers turns a parsed tree into the document the editor reads:
;; one answer per node, parents before children, and the errors the tree
;; carries. The walk is done once and each node is numbered once, so a parent
;; and its children can never be given addresses by two different rules.
(define (surface-answers o)
  (define-values (nodes errors)
    (partition answer-error? (answer-siblings (outline-nodes o) "")))
  ;; The file the document describes is carried even when the tree did not
  ;; learn one: an answer that does not say which file it is about is an
  ;; answer about nothing.
  (answers (or (outline-file o) "") nodes errors))

;; surface-document is the whole answer as the frozen text, which is what a
;; host receives and what write-surface-document puts on disk.
(define (surface-document o)
  (answers-document (surface-answers o)))

;; surface-node-at is the resolve-a-node-address call: given the document text
;; and an address, it answers the node that address names, or #f when the
;; document holds no such node. This is the call an editor may make over the
;; contract alone — the text goes in, plain data comes out, and no part of this
;; package is needed to answer it (TODO item 8, the loader without the
;; notation).
(define (surface-node-at document-text address)
  (answers-at (read-answers document-text) address))


;; answer-siblings answers every node on one level of the tree and, through
;; them, every node below. parent-address is the address of the level's
;; parent, "" at the root.
(define (answer-siblings nodes parent-address)
  (define placed (placed-siblings nodes parent-address))
  (append
   (map (lambda (p) (if (block-node? (car p)) (block-answer p) (fault-answer p)))
        placed)
   (apply append
          (map (lambda (p) (answer-siblings (block-node-children (car p)) (cdr p)))
               (filter (lambda (p) (block-node? (car p))) placed)))))

;; placed-siblings gives every node on one level the address it keeps for as
;; long as its same-kind siblings above it do not move. A node that is neither
;; a block nor an error has no address and is refused, never guessed at.
(define (placed-siblings nodes parent-address)
  (let loop ([rest nodes] [seen '()] [out '()])
    (if (null? rest)
        (reverse out)
        (let* ([n (car rest)]
               [kind (kind-word n)])
          (define ordinal
            (+ 1 (count-of-kind seen kind)))
          (loop (cdr rest)
                (cons kind seen)
                (cons (cons n (join-address parent-address kind ordinal)) out))))))

;; count-of-kind answers how many nodes of one kind this level already placed.
;; Counting per kind is what keeps a paragraph added between two code blocks
;; from renaming either code block.
(define (count-of-kind seen kind)
  (length (filter (lambda (k) (string=? k kind)) seen)))

;; kind-word is the word that goes into an address for a node: a block names
;; itself, an error names what it found. It is the kind the contract promises
;; an address is built from (node-addressing-and-comments.org, lines 13-15).
(define (kind-word n)
  (cond
    [(block-node? n) (symbol->string (block-node-name n))]
    [(error-node? n) (error-node-kind n)]
    [else
     (raise-err 'surface "surface.rkt"
                (format "~a is neither a block nor an error, so it has no address; the surface answers the two node kinds the model holds — fix the tree, or name the new kind here") n)]))

;; join-address adds one level to a path: the kind, then its ordinal.
(define (join-address parent-address kind ordinal)
  (format "~a~a/~a" parent-address kind ordinal))

;; block-answer builds one node answer. The span is the bytes the renderer
;; cuts the node's text out of; children is counted so a reader needs no
;; counting to know what sits inside what (join/INDEX.org, same rule).
(define (block-answer placed)
  (define n (car placed))
  (answer (cdr placed)
          (kind-word n)
          (block-node-name n)
          (block-node-line n)
          (block-node-start n)
          (block-node-end n)
          (length (block-node-children n))))

;; fault-answer builds one error answer. what and what-to-do must both be
;; filled: an error that cannot say what to do is not an error yet
;; (join/INDEX.org), and a tree that broke that rule is named here instead of
;; being passed on as a blank.
(define (fault-answer placed)
  (define n (car placed))
  (define what (error-node-what n))
  (define what-to-do (error-node-what-to-do n))
  (when (or (not (string? what)) (not (string? what-to-do))
            (string=? what "") (string=? what-to-do ""))
    (raise-err 'surface "surface.rkt"
               (format "the ~a error on line ~a carries what ~a and what to do ~a; an error that cannot say what to do is not an error yet — fill both where the tree is built, or the answer names a blank"
                       (error-node-kind n) (error-node-line n) what what-to-do)))
  (answer-error (cdr placed)
                (error-node-kind n)
                (error-node-line n)
                what
                what-to-do))


;; write-surface-document puts one answer where the editor's loader reads it.
;; The target is refused in two cases before a byte moves, and each refusal
;; names what the reader may do:
;;   - the target is the file the answer describes, which would cost the
;;     document it is an answer about (rules/rule-01-never-lose-work.org).
;;   - the target is a directory, which has nowhere for a reader to read from.
;;
;; The text goes to a =.new= file beside the target and is renamed over it in
;; one step, so a crash costs the new file and never the old one. This is not
;; the write generation/write.rkt performs: that one writes a document's own
;; generated content into a declared target, and this one writes the boundary's
;; answer to a file the host named.
(define (write-surface-document target a)
  (define where (target-path target))
  (refuse-target where a)
  (say-step (format "writing the surface answer for ~a → ~a"
                    (or (answers-file a) "an unnamed document") where)
            "the editor's loader reads this file; the text goes to a .new file beside it and is renamed over it in one step")
  (ensure-dir (if (path-only where) (path-only where) "."))
  (with-wait (format "writing the surface answer ~a" where)
             "the disk may be slow, full or gone, so the answer is written beside its target and renamed over it in one step"
    (call-with-output-file (beside-target where)
                           #:exists 'truncate
                           (lambda (out) (display (answers-document a) out)))
    (rename-file-or-directory (beside-target where) where #t)))

;; target-path answers the path a caller named. A path written as a string and
;; a path written as a path are one file and must be one answer.
(define (target-path target)
  (path->string (simplify-path (if (path? target) target (string->path target)))))

;; refuse-target is the door in front of every write of an answer. The two
;; paths are compared as they are written, once simplified — the same test
;; generation/write.rkt makes, and not a device-inode test that pretends to be
;; one.
(define (refuse-target where a)
  (define about (answers-file a))
  (cond
    [(directory-exists? where)
     (raise-err 'surface "surface.rkt"
                (format "~a is a directory; name a file for the answer, because the editor's loader reads a file and not a directory" where))]
    [(and (string? about) (> (string-length about) 0)
          (equal? (simplify-path (string->path about)) (simplify-path (string->path where))))
     (raise-err 'surface "surface.rkt"
                (format "~a is the document the answer describes, and writing it there would cost the source; write the answer beside it under another name" where))]
    [else (void)]))

;; beside-target is the only other path a write of an answer touches: it sits
;; beside the target and the rename leaves nothing behind.
(define (beside-target where)
  (build-path (if (path-only where) (path-only where) ".")
              (string-append (file-name-from-path where) ".new")))
