#lang racket/base

;; One job: the placeable piece list — every piece of the dashboard, the
;; edge it sits on, the size it takes and the order it is placed in.
;; Registered in plan/package-tree.org; lands with TODO item 7.
;;
;; The placement is Racket config and it is data, not code: a piece names
;; an edge, a size and an order, and the drawing puts it where the data
;; says (rule 10). Any piece can go on any edge, and several pieces can
;; share an edge — the order says which comes first.
;;
;; A piece carries no text here: what a piece SHOWS is the meaning side's
;; job, in dashboard.rkt. This file says where the piece goes.

;; piece is one placeable piece: its name, the edge it sits on, the size
;; it takes and the order it is placed in. The size is a count of lines
;; for the top and the bottom edges, and a count of columns for the
;; left and the right edges.
(require racket/string)

;; piece is one placeable piece: its name, the edge it sits on, the size
;; it takes and the order it is placed in.
(struct piece (name edge size order) #:transparent)

;; the-edges are the edges a piece may sit on: the four sides of the
;; screen, and floating, which is a piece that sits on its own in the
;; middle of the screen.
(define the-edges '("top" "bottom" "left" "right" "floating"))

;; the-pieces is the placeable piece list: every piece the dashboard
;; shows. The order is inside an edge, and the edges themselves are
;; drawn in the order a screen is: the top, then the sides, then the
;; bottom.
(define the-pieces
  (list (piece "modeline" "top" 1 0)
        (piece "buffer-bar" "top" 1 1)
        (piece "sidebar" "left" 20 0)
        (piece "status" "bottom" 1 0)))

;; pieces-of answers the pieces that sit on one edge, in the order they
;; are placed in.
(define (pieces-of edge)
  (sort (filter (lambda (p) (string=? (piece-edge p) edge)) the-pieces)
        < #:key piece-order))

;; The placeable piece list, for the meaning side above it.
(provide piece
         piece-name
         piece-edge
         piece-size
         piece-order
         the-edges
         the-pieces
         pieces-of)
