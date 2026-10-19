#lang racket/base
;; One job: a table drawn as HTML.
;; Registered in plan/package-tree.org (data/table-html.rkt).
;;
;; The table itself is decided by data/table.rkt; this file only draws it. The
;; owner asked for the table structure to be kept apart from its rendering, so
;; that a table can be drawn in more than one way without the structure
;; changing. This is the first of those drawings.
;;
;; A missing cell is drawn as an empty cell, never as the word null, because
;; a missing value is not a value and saying null would claim it was one.
;;
;; Who calls it: the to-html command, and anyone who wants a table on a page.

(require "../model/nodes.rkt"
         "table.rkt")

(provide table->html cell->html escape-html)

;; table->html draws a table as an HTML table element: a caption, a head with
;; one cell for each column, and a body with one row for each row of the
;; table. The drawing is one string, with the newlines a reader needs to see
;; the structure.
(define (table->html table)
  (define columns (data-table-columns table))
  (define header (data-table-header table))
  (define rows (data-table-rows table))
  (define caption (data-table-caption table))
  (define out (open-output-string))
  (display "<table>\n" out)
  (when caption
    (display (format "  <caption>~a</caption>\n" (escape-html caption)) out))
  (display "  <thead>\n    <tr>\n" out)
  (for ([cell (in-list (or header '()))])
    (display (format "      <th>~a</th>\n" (escape-html (cell-text cell))) out))
  (for ([column (in-list columns)]
        #:when (not header))
    (display (format "      <th>~a</th>\n" (escape-html (column-name column))) out))
  (display "    </tr>\n  </thead>\n" out)
  (display "  <tbody>\n" out)
  (for ([row (in-list rows)])
    (display "    <tr>\n" out)
    (for ([cell (in-list (table-row-cells row))])
      (display (format "      ~a\n" (cell->html cell)) out))
    (display "    </tr>\n" out))
  (display "  </tbody>\n</table>\n" out)
  (get-output-string out))

;; cell->html draws one cell. A cell that is there holds its value; a cell
;; that is missing holds nothing at all.
(define (cell->html cell)
  (if (table-cell-present? cell)
      (format "<td>~a</td>" (escape-html (table-cell-value cell)))
      "<td></td>"))

;; cell-text gives back the text of a cell, so a header cell and a data cell
;; are read the same way.
(define (cell-text cell)
  (if (table-cell-present? cell) (table-cell-value cell) ""))

;; escape-html writes the characters that HTML reads as markup as the entities
;; that stand for them.
(define (escape-html text)
  (define out (open-output-string))
  (for ([c (in-list (string->list text))])
    (cond
      [(char=? c #\&) (display "&amp;" out)]
      [(char=? c #\<) (display "&lt;" out)]
      [(char=? c #\>) (display "&gt;" out)]
      [(char=? c #\") (display "&quot;" out)]
      [else (display c out)]))
  (get-output-string out))
