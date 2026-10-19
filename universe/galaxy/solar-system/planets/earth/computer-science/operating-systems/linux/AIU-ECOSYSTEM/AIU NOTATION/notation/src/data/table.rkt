#lang racket/base
;; One job: the table — its columns, its header, its rows, and whether the
;; cells fit the columns they sit under.
;; Registered in plan/package-tree.org (data/table.rkt).
;;
;; The owner asked for tables that use AIU keywords instead of punctuation, and
;; for the table to be a structure of its own, not a drawing. This file holds
;; that structure; data/table-html.rkt and data/table-latex.rkt hold the
;; drawings, and neither of them decides what a table is.
;;
;; The form is this, and every line carries a keyword:
;;
;;     table start
;;     caption: Prices
;;     column: name text
;;     column: price number
;;     column: note text optional
;;     header start
;;     cell: name
;;     cell: price
;;     cell: note
;;     header end
;;     row start
;;     row-id: r1
;;     cell: Widget
;;     cell: 9.99
;;     cell:
;;     row end
;;     table end
;;
;; A cell with an empty value is a MISSING value, not an empty string. A
;; missing value is only allowed in a column that says optional.
;;
;; Who calls it: the JSON writer, which needs the table as data; the HTML and
;; LaTeX writers, which need the table as a structure; and the validator, which
;; tells an author what does not fit.

(require racket/list
         racket/string
         "../errors/raise.rkt"
         "../model/nodes.rkt"
         "../model/properties.rkt")

(provide column column-name column-type column-optional?
         table-cell table-cell-value table-cell-present?
         table-row table-row-id table-row-cells
         data-table data-table-caption data-table-columns data-table-header
         data-table-rows
         read-table validate-table table-errors value-fits-type? column-types
         declaration-values)

;; A column says what a cell under it may hold: a name, a type, and whether
;; the column may be left empty. The last field is named with a question mark
;; so its answer reads as a question: may this column be left empty?
(struct column (name type optional?) #:transparent)

;; A cell holds a value and says whether it is there. A cell that is not there
;; is a MISSING value, which is not the same as a cell holding "".
(struct table-cell (value present?) #:transparent)

;; A row holds an optional identifier and its cells, in the order the columns
;; were declared.
(struct table-row (id cells) #:transparent)

;; A table holds everything a table is: a caption, its columns, its header row
;; and its rows.
(struct data-table (caption columns header rows) #:transparent)

;; The types a column may declare. A type outside this list is not read as a
;; type, and the validator says so.
(define column-types
  '(text number integer bool date json))

;; The keyword that says a row is this row, so a reader can point at it.
(define row-id-keyword 'row-id)

;; The keyword that holds one cell's value.
(define cell-keyword 'cell)

;; The keyword that declares one column.
(define column-keyword 'column)

;; The keyword that holds the table's caption.
(define caption-keyword 'caption)

;; declaration-values picks the declarations of a node that carry one keyword,
;; and gives back their values in the order they were written.
(define (declaration-values node keyword)
  (for/list ([d (in-list (block-node-declarations node))]
             #:when (eq? (first d) keyword))
    (second d)))

;; read-table reads a table block and answers the table it holds, or #f when
;; the block is not a table.
;;
;; The columns come from the column declarations under the table's own start
;; line. The header and the rows are the child blocks: a header block and any
;; number of row blocks. A table with no header block has no header, and that
;; is allowed — a table may carry only rows.
(define (read-table node)
  (and (block-node? node)
       (eq? (block-node-name node) 'table)
       (data-table (read-caption node)
                   (read-columns node)
                   (read-header node)
                   (read-rows node))))

;; read-caption reads the caption of a table, or #f when the table has no
;; caption line. A table may go without one, so the absence is a fact and not
;; a failure.
(define (read-caption node)
  (define values (declaration-values node caption-keyword))
  (if (null? values) #f (car values)))

;; read-columns reads the column declarations of a table into columns.
(define (read-columns node)
  (for/list ([text (in-list (declaration-values node column-keyword))])
    (read-column text)))

;; read-column reads one column declaration: a name, a type, and the word
;; optional when the column may be left empty. A declaration that names no
;; type is read as a text column, because text is the type that fits anything.
(define (read-column text)
  (define parts (string-split (string-trim text) " " #:trim? #t #:repeat? #t))
  (cond
    [(null? parts) (column "" 'text #f)]
    [(null? (cdr parts)) (column (car parts) 'text #f)]
    [else
     (define type (string->symbol (cadr parts)))
     (define optional (and (>= (length parts) 3)
                           (string=? (caddr parts) "optional")))
     (column (car parts) type optional)]))

;; read-header reads the header row of a table: the cells of the header child
;; block, in order. A table with no header block has no header.
(define (read-header node)
  (define header (for/or ([child (in-list (block-node-children node))]
                          #:when (eq? (block-node-name child) 'header))
                  child))
  (and header (read-cells header)))

;; read-rows reads the rows of a table: every row child block, in order.
(define (read-rows node)
  (for/list ([child (in-list (block-node-children node))]
             #:when (eq? (block-node-name child) 'row))
    (table-row (property-of child row-id-keyword)
               (read-cells child))))

;; read-cells reads the cells of a header or a row: the cell declarations, in
;; the order they were written. A cell whose value is empty is a MISSING
;; value.
(define (read-cells node)
  (for/list ([text (in-list (declaration-values node cell-keyword))])
    (if (string=? (string-trim text) "")
        (table-cell "" #f)
        (table-cell text #t))))

;; validate-table reads a table and says what does not fit, in the order the
;; problems appear. Each problem is a list of three fields: what kind of
;; problem it is, what is wrong, and what to do about it. A table with no
;; problems gives an empty list.
(define (validate-table table)
  (append (check-columns table)
          (check-header table)
          (check-rows table)))

;; check-columns says what is wrong with the columns themselves: a column that
;; names no type that exists, and a table with no columns at all.
(define (check-columns table)
  (define columns (data-table-columns table))
  (append
   (if (null? columns)
       (list (list 'table-has-no-columns
                   "the table declares no column"
                   "add a `column:` line under the table's start line, one for each column"))
       '())
   (for/list ([c (in-list columns)]
              #:when (not (memq (column-type c) column-types)))
     (list (list 'unknown-column-type
                 (format "the column ~a has the type ~a, which is not a type a column may have"
                         (column-name c) (column-type c))
                 (format "use one of ~a" column-types))))))

;; check-header says what is wrong with the header: the header must have as
;; many cells as the table has columns, or no header at all.
(define (check-header table)
  (define header (data-table-header table))
  (define columns (data-table-columns table))
  (if (and header (not (= (length header) (length columns))))
      (list (list 'header-does-not-match-the-columns
                  (format "the header holds ~a cell(s) and the table declares ~a column(s)"
                          (length header) (length columns))
                  "give the header one cell for each column, or leave the header out"))
      '()))

;; check-rows says what is wrong with each row: too few cells, too many, a
;; value that does not fit its column, and a missing value in a column that may
;; not be left empty.
(define (check-rows table)
  (define columns (data-table-columns table))
  (apply append
         (for/list ([row (in-list (data-table-rows table))]
                    [index (in-naturals)])
           (row-problems row columns index))))

;; row-problems says what is wrong with one row, given the columns it sits
;; under and the index it holds in the table.
(define (row-problems row columns index)
  (define cells (table-row-cells row))
  (define where (row-where row index))
  (append
   (cond
     [(> (length cells) (length columns))
      (list (list 'row-has-too-many-cells
                  (format "the row ~a holds ~a cell(s) and the table declares ~a column(s)"
                          where (length cells) (length columns))
                  "give the row one cell for each column, or remove a cell"))]
     [(< (length cells) (length columns))
      (list (list 'row-has-too-few-cells
                  (format "the row ~a holds ~a cell(s) and the table declares ~a column(s)"
                          where (length cells) (length columns))
                  "give the row one cell for each column, or remove a column"))]
     [else '()])
   (for/list ([cell (in-list cells)]
              [column (in-list columns)]
              #:when (and (table-cell-present? cell)
                          (not (value-fits-type? (table-cell-value cell) (column-type column)))))
     (list (list 'value-does-not-fit-the-column
                 (format "the cell ~a of the row ~a holds ~a, which is not a ~a"
                         (column-name column) where (table-cell-value cell) (column-type column))
                 (format "write a value of the type ~a, or change the type of the column"
                         (column-type column)))))
   (for/list ([cell (in-list cells)]
              [column (in-list columns)]
              #:when (and (not (table-cell-present? cell))
                          (not (column-optional? column))))
     (list (list 'missing-value-in-a-column-that-may-not-be-empty
                 (format "the cell ~a of the row ~a is missing, and that column may not be empty"
                         (column-name column) where)
                 "give the cell a value, or mark the column optional")))))

;; row-where says which row a problem is in, in words: its identifier when it
;; has one, and its place in the table when it does not.
(define (row-where row index)
  (define id (table-row-id row))
  (if (and id (not (string=? (string-trim id) "")))
      (format "with the id ~a" id)
      (format "at the place ~a" (add1 index))))

;; value-fits-type? says whether a value may sit under a column of that type.
;; A missing value is not asked about here: whether a column may be left empty
;; is the column's own business, and the validator checks that.
(define (value-fits-type? value type)
  (define trimmed (string-trim value))
  (cond
    [(eq? type 'text) #t]
    [(eq? type 'number) (and (number? (string->number trimmed)) #t)]
    [(eq? type 'integer)
     (define n (string->number trimmed))
     (and n (exact-integer? n) #t)]
    [(eq? type 'bool) (member trimmed '("true" "false" "yes" "no")) ]
    [(eq? type 'date) (date-shaped? trimmed)]
    [(eq? type 'json) (json-shaped? trimmed)]
    [else #f]))

;; date-shaped? says whether a value looks like a date: four digits, a dash,
;; two digits, a dash, two digits.
(define (date-shaped? value)
  (and (= (string-length value) 10)
       (char=? (string-ref value 4) #\-)
       (char=? (string-ref value 7) #\-)
       (string->number (substring value 0 4))
       (string->number (substring value 5 7))
       (string->number (substring value 8 10))))

;; json-shaped? says whether a value holds something that reads as JSON: an
;; object, an array, a quoted string, a number, true, false or null.
(define (json-shaped? value)
  (define trimmed (string-trim value))
  (and (pair? trimmed)
       (let ([c (string-ref trimmed 0)])
         (or (char=? c #\{) (char=? c #\[) (char=? c #\")
             (char=? c #\t) (char=? c #\f) (char=? c #\n)
             (char-numeric? c) (char=? c #\-)))))

;; table-errors says what is wrong with a table, one plain sentence per
;; problem, for a caller that prints a line and does not want a structure.
(define (table-errors table)
  (for/list ([problem (in-list (validate-table table))])
    (format "~a: ~a; what to do: ~a" (car problem) (second problem) (third problem))))
