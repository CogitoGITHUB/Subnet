#lang racket/base
;; One job: write AIU text — the .aiu form — from blocks that are described as
;; data.
;; Registered in plan/package-tree.org (data/aiu-text.rkt).
;;
;; The owner asked for the two ways to move between AIU and JSON, and this file
;; holds the AIU side of the second one: JSON comes back as blocks described as
;; data, and this file writes those blocks as a .aiu page. A page written this
;; way is a page a person can read, and the reader is the reason the format
;; exists.
;;
;; The blocks are described with plain lists, so a caller may build them by
;; hand or read them from JSON without this file knowing where they came from:
;;
;;   (list 'title "The first page")
;;   (list 'paragraph "The body of the page.")
;;   (list 'heading (list 'level 2 'number "1.1" 'text "A subheading"))
;;   (list 'table (list 'caption "Prices"
;;                        'columns (list (list 'name "name" 'type "text" 'optional #f))
;;                        'header (list "name")
;;                        'rows (list (list 'id "r1" 'cells (list (list "Widget" #t))))))
;;   (list 'data <any JSON value>)
;;
;; The heading's number is written only as the level, never as the number: the
;; number is computed from where the heading sits, so a page written from these
;; blocks has the same numbers as the page it came from.
;;
;; Who calls it: the from-json command, and any caller that holds blocks as
;; data and wants a page.

(require racket/list
         racket/string
         "../errors/raise.rkt"
         "json.rkt"
         "table.rkt")

(provide blocks->aiu-text block->aiu-text)

;; blocks->aiu-text writes a list of blocks as a .aiu page. Each block is
;; written in the three-line form: the name and start, the content on its own
;; lines, then the name and end.
(define (blocks->aiu-text blocks)
  (string-join (for/list ([block (in-list blocks)]) (block->aiu-text block)) "\n\n"))

;; block->aiu-text writes one block as a .aiu block. A block of a kind nobody
;; registered is refused rather than written out in a form the parser would
;; not read back.
(define (block->aiu-text block)
  (define kind (first block))
  (cond
    [(eq? kind 'title) (simple-block "title" (second block))]
    [(eq? kind 'paragraph) (simple-block "paragraph" (second block))]
    [(eq? kind 'heading) (heading-text (second block))]
    [(eq? kind 'table) (table-text (second block))]
    ;; A code block is written as a code block, with its body exactly as it
    ;; was, because the body of a code block is text the parser never read.
    [(eq? kind 'code) (simple-block "code" (second block))]
    [(eq? kind 'data) (data-text (second block))]
    [else
     (raise-err 'data "aiu-text.rkt"
                (format "~a is not a block this file can write; the blocks that exist are title, paragraph, heading, table, code and data"
                        kind))]))

;; simple-block writes a block that holds nothing but its words.
(define (simple-block name text)
  (string-join (list (format "~a start" name)
                     (string-trim text)
                     (format "~a end" name))
               "\n"))

;; heading-text writes a heading block. The level is written as a declaration
;; when it is not the default, so the number that follows from it is computed
;; by the same rule that numbers every other heading.
(define (heading-text spec)
  (define level (lookup 'level spec 1))
  (define text (lookup 'text spec ""))
  (define lines (list "heading start"))
  (unless (= level 1)
    (set! lines (append lines (list (format "level: ~a" level)))))
  (set! lines (append lines (list (string-trim text) "heading end")))
  (string-join lines "\n"))

;; table-text writes a table block: the caption, the columns, the header and
;; the rows, each on its own line with its keyword.
(define (table-text spec)
  (define caption (lookup 'caption spec #f))
  (define columns (lookup 'columns spec '()))
  (define header (lookup 'header spec '()))
  (define rows (lookup 'rows spec '()))
  (define lines (list "table start"))
  (when caption
    (set! lines (append lines (list (format "caption: ~a" caption)))))
  (for ([column (in-list columns)])
    (define name (lookup 'name column ""))
    (define type (lookup 'type column "text"))
    (define optional (lookup 'optional column #f))
    (set! lines (append lines
                         (list (format "column: ~a ~a~a" name type
                                       (if optional " optional" ""))))))
  (when (pair? header)
    (set! lines (append lines (list "header start")))
    (for ([cell (in-list header)])
      (set! lines (append lines (list (format "cell: ~a" (cell-value cell))))))
    (set! lines (append lines (list "header end"))))
  (for ([row (in-list rows)])
    (set! lines (append lines (list "row start")))
    (define id (lookup 'id row #f))
    (when (and id (not (string=? (string-trim id) "")))
      (set! lines (append lines (list (format "row-id: ~a" id)))))
    (for ([cell (in-list (lookup 'cells row '()))])
      (set! lines (append lines
                           (list (format "cell: ~a" (cell-value cell))))))
    (set! lines (append lines (list "row end"))))
  (set! lines (append lines (list "table end")))
  (string-join lines "\n"))

;; data-text writes a data block: a block whose body is any JSON value. The
;; body is written as JSON, so the block keeps what it holds.
(define (data-text value)
  (string-join (list "data start" (json->text value) "data end") "\n"))

;; lookup reads one field of a described block. The description is a flat list
;; of key and value, so the key is looked for by walking the list and the
;; value is what follows it. A field the description does not hold answers the
;; fallback, so a caller may leave a field out.
(define (lookup key spec fallback)
  (cond
    [(not (list? spec)) fallback]
    [(null? spec) fallback]
    [(eq? (car spec) key)
     (if (null? (cdr spec)) fallback (cadr spec))]
    [else (lookup key (cdr spec) fallback)]))

;; cell-value reads the value of a described cell. A cell is a pair of the
;; value and whether the value is there, and a cell that is not there is
;; written with an empty value, because a missing value is an empty cell.
(define (cell-value cell)
  (if (and (pair? cell) (pair? (cdr cell)) (cadr cell)) (car cell) ""))
