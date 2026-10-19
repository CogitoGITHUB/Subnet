#lang racket/base
;; One job: the heading numbers — 1, 1.1, 1.1.1 — computed from the document.
;; Registered in plan/package-tree.org (model/numbering.rkt).
;;
;; The number is never written by hand. The author writes a heading block and
;; says how deep it is with a `level:` declaration; the number follows from
;; where the heading sits in the page. That is the same law the addresses
;; follow: computed from kind and position, never authored.
;;
;; The rule, in one sentence: walk the headings in the order they appear; the
;; heading at level L takes the next number at that level and restarts every
;; deeper level; the number is those numbers joined with a dot.
;;
;;     heading start   -> 1
;;     heading start   -> 1.1
;;     heading start   -> 1.1.1
;;     heading start   -> 1.2
;;     heading start   -> 2
;;
;; The Rust crate has the same rule in its own numbering file, so a page
;; numbered by the binary and a document numbered by the model agree.
;;
;; Who calls it: the reader that draws an outline, and the editor that asks
;; for the number of the heading under the cursor.

(require racket/list
         racket/string
         "nodes.rkt"
         "outline.rkt"
         "properties.rkt"
         "../errors/raise.rkt")

;; Provided so a caller can read the numbers of a document and look one up by
;; the line the heading starts on.
(provide heading-numbers number-at heading-level-of)

;; The one level keyword. A heading says how deep it is with this.
(define level-keyword 'level)

;; The default level: a heading with no level declaration is a top heading.
(define default-level 1)

;; heading-numbers reads the document and answers the numbers of its
;; headings, in the order the headings appear. Each number is a list of three
;; fields: the number as it is written ("1", "1.1"), the level, and the line
;; the heading starts on.
;;
;; The walk is the tree's own order: a block, then the blocks inside it. A
;; heading nested inside a paragraph is numbered where it stands, so the
;; numbering follows the page and not the block names.
(define (heading-numbers o)
  (define counters (box '()))
  (define out (box '()))
  (for ([node (in-list (outline-nodes o))])
    (walk node counters out))
  (reverse (unbox out)))

;; walk numbers the headings inside one node, then the nodes inside it. The
;; counters and the numbers travel in boxes, because a walk that ends must
;; hand back what it counted.
(define (walk node counters out)
  (when (block-node? node)
    (when (eq? (block-node-name node) 'heading)
      (define level (heading-level-of node))
      (define taken (take-number (unbox counters) level))
      (set-box! counters taken)
      (set-box! out (cons (list (number-text taken level)
                                level
                                (block-node-line node))
                           (unbox out))))
    (for ([child (in-list (block-node-children node))])
      (walk child counters out))))

;; Take the next number at this level and restart every deeper level.
(define (take-number counters level)
  (define index (sub1 level))
  (define grown
    (if (> (length counters) index)
      (append counters '())
      (append counters (make-list (- (add1 index) (length counters)) 0))))
  (define bumped (append grown '()))
  (set! bumped (list-set bumped index (add1 (list-ref bumped index))))
  ;; Every deeper level restarts, because a new heading at this level puts the
  ;; headings under it back at their first number.
  (take bumped (add1 index)))

;; The number as it is written: the counters up to this level, joined with a dot.
(define (number-text counters level)
  (string-join (map number->string (take counters level)) "."))

;; number-at answers the number of the heading that starts on this line, or #f
;; when the line holds no heading. A caller that holds one node asks this for
;; the line that node is on.
(define (number-at o line)
  (define found (for/or ([entry (in-list (heading-numbers o))])
                  (and (= (third entry) line) entry)))
  (and found (first found)))

;; heading-level-of reads the level a heading declares, or 1 when it declares
;; none. A heading with a `level:` value that cannot be read was already
;; reported by the parser as a `bad-heading-level` error; here it falls back
;; to level 1 so the numbering never counts a level it could not read.
(define (heading-level-of node)
  (define value (property-of node level-keyword))
  (cond
    [(not value) default-level]
    [else
     (define level (read-level value))
     (if level level default-level)]))

;; read-level reads a level value: a whole number of 1 or more. Anything else
;; is not a level, so it is not read as one.
(define (read-level value)
  (define trimmed (string-trim value))
  (define n (string->number trimmed))
  (and n
       (exact-integer? n)
       (>= n 1)
       n))
