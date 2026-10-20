#lang racket/base
;; One job: the dashboard check — every piece of the placeable piece list
;; is really drawn, on an edge the drawing knows. Registered in
;; plan/package-tree.org; lands with TODO item 7.
;;
;; Rule 10 says a piece may go on any side, and the failure it exists to
;; prevent is "a piece welded to one edge". A drawing that quietly drops a
;; piece is that failure wearing a different hat, so the check draws the
;; dashboard and asks whether every piece's text is on the screen.
;;
;; The check runs from the gate directory, so the package is reached by a
;; relative path: a module path that holds a space cannot be opened by
;; an absolute one on this Racket.

(require racket/string
         "../editor/src/dashboard/dashboard.rkt"
         "../editor/src/dashboard/pieces.rkt")

;; drawn-edges answers the edges the drawing knows: the four sides and
;; floating. A piece on any other edge would be dropped.
(define known-edges the-edges)

;; piece-is-drawn answers whether the text of one piece is on the screen.
;; The text of a piece may be more than one line, and then every line of
;; it must be there: a piece that shows only half of its text is a piece
;; that was cut, which is the fault this check exists to catch.
(define (piece-is-drawn piece screen)
  (define text (string-trim (piece-content (piece-name piece) (fake-state))))
  (and (not (string=? text ""))
       (for/and ([line (in-list (string-split text "\n"))])
         (for/or ([row (in-list screen)])
           (string-contains? row (string-trim line))))))

;; fake-state is the state the check asks the meaning side about. The
;; check does not edit anything, so the state is a plain one.
(define (fake-state)
  (hash 'file "check"
        'lines "1"
        'bytes "1"
        'pending "0"
        'layer "normal"))

;; main checks the pieces and answers what is wrong, one line per fault.
;; It exits non-zero when a fault is found.
(define (main)
  (define faults
    (append
     (for/list ([piece (in-list the-pieces)]
                #:unless (member (piece-edge piece) known-edges))
       (format "the piece ~a sits on the edge ~a, and the drawing knows only ~a"
               (piece-name piece) (piece-edge piece) (string-join known-edges ", ")))
     (for/list ([piece (in-list the-pieces)]
                #:when (not (piece-is-drawn piece (draw-screen))))
       (format "the piece ~a is in the placeable piece list, but its text is not on the screen"
               (piece-name piece)))))
  (if (null? faults)
      (begin
        (printf "OK dashboard-check — ~a pieces checked, every one of them is drawn\n"
                (length the-pieces))
        (exit 0))
      (begin
        (for-each (lambda (fault) (printf "DASHBOARD — ~a\n" fault)) faults)
        (printf "DASHBOARD — ~a faults in ~a pieces\n" (length faults) (length the-pieces))
        (exit 1))))

;; draw-screen answers the drawn screen, one line per row.
(define (draw-screen)
  (draw-dashboard the-pieces (fake-state)))

;; The check, for the dispatcher above.
(module+ main
  (main))
