#lang racket/base
;; One job: a table drawn as LaTeX.
;; Registered in plan/package-tree.org (data/table-latex.rkt).
;;
;; The table itself is decided by data/table.rkt; this file only draws it. The
;; owner asked for the table structure to be kept apart from its rendering, so
;; that a table can be drawn in more than one way without the structure
;; changing. This is the second of those drawings.
;;
;; A missing cell is drawn as an empty cell, never as the word null, because a
;; missing value is not a value.
;;
;; Who calls it: the to-latex command, and anyone who wants a table in a
;; paper.

(require "../model/nodes.rkt"
         "table.rkt")

(provide table->latex cell->latex escape-latex)

;; table->latex draws a table as a LaTeX tabular: a caption, a rule under the
;; header, one column of left-aligned text, and the rows.
(define (table->latex table)
  (define columns (data-table-columns table))
  (define header (data-table-header table))
  (define rows (data-table-rows table))
  (define caption (data-table-caption table))
  (define out (open-output-string))
  (display "\\begin{tabular}{|" out)
  (for ([column (in-list columns)])
    (display "l|" out))
  (display "}\n" out)
  (when caption
    (display (format "\\caption{~a}\n" (escape-latex caption)) out))
  (display "\\hline\n" out)
  (when header
    (display (row-line header) out)
    (display " \\\\\n" out)
    (display "\\hline\n" out))
  (for ([row (in-list rows)])
    (display (row-line (table-row-cells row)) out)
    (display " \\\\\n" out))
  (display "\\hline\n" out)
  (display "\\end{tabular}\n" out)
  (get-output-string out))

;; row-line draws the cells of one row, with the LaTeX column mark between
;; them and not after the last one, because a mark after the last cell is a
;; column that does not exist.
(define (row-line cells)
  (define out (open-output-string))
  (let loop ([rest cells] [first? #t])
    (cond
      [(null? rest) (void)]
      [else
       (unless first? (display " & " out))
       (display (cell->latex (car rest)) out)
       (loop (cdr rest) #f)]))
  (get-output-string out))

;; cell->latex draws one cell. A cell that is missing holds nothing.
(define (cell->latex cell)
  (if (table-cell-present? cell)
      (escape-latex (table-cell-value cell))
      ""))

;; escape-latex writes the characters LaTeX reads as markup as the commands
;; that stand for them.
(define (escape-latex text)
  (define out (open-output-string))
  (for ([c (in-list (string->list text))])
    (cond
      [(char=? c #\&) (display "\\&" out)]
      [(char=? c #\%) (display "\\%" out)]
      [(char=? c #\$) (display "\\$" out)]
      [(char=? c #\#) (display "\\#" out)]
      [(char=? c #\_) (display "\\_" out)]
      [(char=? c #\{) (display "\\{" out)]
      [(char=? c #\}) (display "\\}" out)]
      [(char=? c #\~) (display "\\textasciitilde{}" out)]
      [(char=? c #\^) (display "\\textasciicircum{}" out)]
      [(char=? c #\\) (display "\\textbackslash{}" out)]
      [else (display c out)]))
  (get-output-string out))
