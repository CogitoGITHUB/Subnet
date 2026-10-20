#lang racket/base
;; One job: the selection — the region the commands act on. Registered
;; in plan/package-tree.org; lands with TODO item 14.
;;
;; A selection is a REGION, not a point: an anchor where the selection
;; began and a point where the cursor stands now. The text of the
;; region is the text between them, and the hot path holds the text, so
;; the region is asked of the hot path for its text.
;;
;; The selection lives in the BUFFER area, below the commands area,
;; because the commands area asks it, and an area may only reach
;; DOWNWARD.
;;
;; A selection that was never started is nothing, and nothing is not a
;; region: an absent selection is absent, and empty is not a value.
;;
;; Registered in plan/package-tree.org; lands with TODO item 14.

(require racket/list
         racket/string)

;; region is a selection: the place it began and the place it ends.
(struct region (anchor point) #:transparent)

;; start-region answers the region that begins at a place. A selection
;; that starts where the cursor stands is a region of one place, and it
;; is still a region.
(define (start-region at)
  (region at at))

;; grow-region answers the region that reaches a place: the anchor
;; stays, the point moves.
(define (grow-region the-region at)
  (region (region-anchor the-region) at))

;; shrink-region answers the region that gives a place back: the anchor
;; stays, the point moves the other way.
(define (shrink-region the-region at)
  (region (region-anchor the-region) at))

;; region-from answers the region between two places, in the order they
;; are: a region always runs from the smaller place to the larger one,
;; so the text of a region is the same whichever end the cursor is on.
(define (region-from a b)
  (if (<= a b) (region a b) (region b a)))

;; region-text answers the text of a region, as the hot path holds it.
;; The text is asked of the hot path, because the hot path owns the
;; text of the buffer; the region only says where it runs.
(define (region-text ask the-region)
  (if (not the-region)
      ""
      (let* ([ends (region-from (region-anchor the-region) (region-point the-region))])
        (ask "select" (hasheq 'from (number->string (region-anchor ends))
                              'to (number->string (region-point ends)))))))

;; region-line answers the region as one line of text: where it starts,
;; where it ends, and whether it holds anything at all.
(define (region-line the-region)
  (if (not the-region)
      "no selection"
      (format "selection: ~a to ~a" (region-anchor the-region) (region-point the-region))))

;; The region, for the commands area above it.
(provide region
         region-anchor
         region-point
         start-region
         grow-region
         shrink-region
         region-from
         region-text
         region-line)
