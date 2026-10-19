#lang racket/base
;; One job: JSON — read it, write it, and move between AIU and JSON.
;; Registered in plan/package-tree.org (data/json.rkt).
;;
;; The owner asked for JSON compatibility: AIU structures go out as JSON and
;; JSON comes back as AIU structures, in both directions, without losing what
;; the target format can hold. This file is the one place that knows what a
;; JSON value is in Racket, so the parser and the writer can never disagree
;; about a shape.
;;
;; A JSON value is one of these, and nothing else:
;;
;;   object  (json-object entries)   entries is a list of (key . value) pairs
;;                                   held in the order they were written, so a
;;                                   document keeps its shape through a round
;;                                   trip
;;   array   a list of values
;;   string  a Racket string
;;   number  an exact integer, or an inexact real
;;   true    #t
;;   false   #f
;;   null    the symbol 'null — not #f, because #f is also false
;;
;; Who calls it: the Nushell side, which wants structured values and not text;
;; the from-json command, which turns a JSON file back into a .aiu page; and
;; the to-json command, which turns a parsed page into JSON.

(require racket/format
         racket/list
         racket/port
         racket/string
         "../errors/raise.rkt"
         "../model/nodes.rkt"
         "../model/outline.rkt"
         "../model/numbering.rkt"
         "../model/properties.rkt"
         "table.rkt")

(provide parse-json json->text json-object json-object? json-object-entries
         json-object-ref json-object-set!
         json-null json-null? json-value? json-write-aiu
         document->json json->blocks blocks->json outline->blocks)

;; json-object holds the members of a JSON object in the order they were
;; written. A hash would lose that order, and the order is part of what a
;; round trip must keep.
(struct json-object (entries) #:transparent #:mutable)

;; The symbol that stands for JSON's null. It is not #f, because #f is also
;; how JSON's false is read, and a reader must not confuse the two.
(define json-null 'null)

;; json-null? answers whether a value is JSON's null. It is not called null?
;; because that name would shadow the list check of racket everywhere in this
;; file, and a list is not the same thing as a JSON null.
(define (json-null? v) (eq? v json-null))

;; json-value? answers whether a value is one of the shapes this file reads and
;; writes. A caller that hands it something else is told so instead of having
;; it written out as nonsense.
(define (json-value? v)
  (or (json-object? v)
      (list? v)
      (string? v)
      (number? v)
      (boolean? v)
      (json-null? v)))

;; json-object-ref finds a member of an object by its key, or #f.
(define (json-object-ref obj key)
  (for/or ([entry (in-list (json-object-entries obj))])
    (and (equal? (car entry) key) (cdr entry))))

;; json-object-set! puts a member into an object, replacing the value of a key
;; that is already there and keeping the order of the keys either way.
(define (json-object-set! obj key value)
  (define entries (json-object-entries obj))
  (define found (for/or ([entry (in-list entries)] #:when (equal? (car entry) key))
                 entry))
  (if found
      (set-json-object-entries!
       obj
       (for/list ([entry (in-list entries)])
         (if (equal? (car entry) key) (cons key value) entry)))
      (set-json-object-entries! obj (append entries (list (cons key value))))))

;; parse-json reads a JSON text and answers the value it holds.
;;
;; The parser is written here, by hand, because the package takes no library
;; from outside: a reader of the tree must be able to see every rule the
;; reader follows. The rules are the ones JSON says: an object, an array, a
;; string, a number, true, false and null; nothing else, and nothing after the
;; value.
(define (parse-json text)
  (define chars (string->list text))
  (define pos (box 0))
  (skip-space chars pos)
  (when (>= (unbox pos) (length chars))
    (raise-err 'json "json.rkt" "malformed JSON at position 0: the text holds no value"))
  (define value (read-value chars pos))
  (skip-space chars pos)
  (unless (= (unbox pos) (length chars))
    (raise-err 'json "json.rkt"
               (format "malformed JSON at position ~a: characters follow the value" (unbox pos))))
  value)

;; skip-space moves past the spaces, the tabs, the newlines and the carriage
;; returns, which JSON allows between any two tokens.
(define (skip-space chars pos)
  (let loop ()
    (when (and (< (unbox pos) (length chars))
               (memv (list-ref chars (unbox pos)) '(#\space #\tab #\newline #\return)))
      (set-box! pos (add1 (unbox pos)))
      (loop))))

;; read-value reads one JSON value, whatever it turns out to be, and leaves the
;; position after it.
(define (read-value chars pos)
  (skip-space chars pos)
  (when (>= (unbox pos) (length chars))
    (raise-err 'json "json.rkt"
               (format "malformed JSON at position ~a: the text ends where a value was expected"
                       (unbox pos))))
  (define c (list-ref chars (unbox pos)))
  (cond
    [(char=? c #\{) (read-object chars pos)]
    [(char=? c #\[) (read-array chars pos)]
    [(char=? c #\") (read-string chars pos)]
    [(char=? c #\t) (read-literal chars pos "true" #t)]
    [(char=? c #\f) (read-literal chars pos "false" #f)]
    [(char=? c #\n) (read-literal chars pos "null" json-null)]
    [(or (char-numeric? c) (char=? c #\-)) (read-number chars pos)]
    [else
     (raise-err 'json "json.rkt"
                (format "malformed JSON at position ~a: ~a is not the start of a value"
                        (unbox pos) c))]))

;; read-object reads a JSON object: a { , members separated by commas, and a }.
;; A member is a quoted key, a colon, and a value. An empty object is the one
;; with the closing brace right after the opening one.
(define (read-object chars pos)
  (set-box! pos (add1 (unbox pos)))
  (define entries '())
  (skip-space chars pos)
  (cond
    [(and (< (unbox pos) (length chars)) (char=? (list-ref chars (unbox pos)) #\}))
     (set-box! pos (add1 (unbox pos)))
     (json-object entries)]
    [else
     (let loop ()
       (skip-space chars pos)
       (when (>= (unbox pos) (length chars))
         (raise-err 'json "json.rkt"
                    (format "malformed JSON at position ~a: the object is not closed" (unbox pos))))
       (unless (char=? (list-ref chars (unbox pos)) #\")
         (raise-err 'json "json.rkt"
                    (format "malformed JSON at position ~a: a member must start with a quoted name"
                            (unbox pos))))
       (define key (read-string chars pos))
       (skip-space chars pos)
       (unless (and (< (unbox pos) (length chars)) (char=? (list-ref chars (unbox pos)) #\:))
         (raise-err 'json "json.rkt"
                    (format "malformed JSON at position ~a: a member needs a colon" (unbox pos))))
       (set-box! pos (add1 (unbox pos)))
       (define value (read-value chars pos))
       (set! entries (append entries (list (cons key value))))
       (skip-space chars pos)
       (when (>= (unbox pos) (length chars))
         (raise-err 'json "json.rkt"
                    (format "malformed JSON at position ~a: the object is not closed" (unbox pos))))
       (define c (list-ref chars (unbox pos)))
       (cond
         [(char=? c #\,) (set-box! pos (add1 (unbox pos))) (loop)]
         [(char=? c #\}) (set-box! pos (add1 (unbox pos))) (json-object entries)]
         [else
          (raise-err 'json "json.rkt"
                     (format "malformed JSON at position ~a: a member needs a comma or a closing brace"
                             (unbox pos)))]))]))

;; read-array reads a JSON array: a [ , values separated by commas, and a ].
;; The comma between two values is optional in JSON, so a value that follows
;; another one straight away is read as well. An empty array is the one with
;; the closing bracket right after the opening one.
(define (read-array chars pos)
  (set-box! pos (add1 (unbox pos)))
  (define items '())
  (skip-space chars pos)
  (cond
    [(and (< (unbox pos) (length chars)) (char=? (list-ref chars (unbox pos)) #\]))
     (set-box! pos (add1 (unbox pos)))
     '()]
    [else
     (let loop ()
       (define value (read-value chars pos))
       (set! items (append items (list value)))
       (skip-space chars pos)
       (when (>= (unbox pos) (length chars))
         (raise-err 'json "json.rkt"
                    (format "malformed JSON at position ~a: the array is not closed" (unbox pos))))
       (define c (list-ref chars (unbox pos)))
       (cond
         [(char=? c #\,) (set-box! pos (add1 (unbox pos))) (loop)]
         [(char=? c #\]) (set-box! pos (add1 (unbox pos))) items]
         [else (loop)]))]))

;; read-string reads a quoted string and gives back its text, with the escapes
;; JSON defines read: \" \\ \/ \b \f \n \r \t and \uXXXX.
(define (read-string chars pos)
  (set-box! pos (add1 (unbox pos)))
  (let loop ([out '()])
    (when (>= (unbox pos) (length chars))
      (raise-err 'json "json.rkt"
                 (format "malformed JSON at position ~a: the string is not closed" (unbox pos))))
    (define c (list-ref chars (unbox pos)))
    (set-box! pos (add1 (unbox pos)))
    (cond
      [(char=? c #\") (list->string (reverse out))]
      [(char=? c #\\) (read-escape chars pos out loop)]
      [else (loop (cons c out))])))

;; read-escape reads the character after a backslash inside a string and puts
;; the text it stands for into the string being built.
(define (read-escape chars pos out loop)
  (when (>= (unbox pos) (length chars))
    (raise-err 'json "json.rkt"
               (format "malformed JSON at position ~a: the escape holds no character" (unbox pos))))
  (define c (list-ref chars (unbox pos)))
  (set-box! pos (add1 (unbox pos)))
  (cond
    [(char=? c #\") (loop (cons #\" out))]
    [(char=? c #\\) (loop (cons #\\ out))]
    [(char=? c #\/) (loop (cons #\/ out))]
    [(char=? c #\b) (loop (cons #\backspace out))]
    [(char=? c #\f) (loop (cons #\page out))]
    [(char=? c #\n) (loop (cons #\newline out))]
    [(char=? c #\r) (loop (cons #\return out))]
    [(char=? c #\t) (loop (cons #\tab out))]
    [(char=? c #\u)
     (define hex (list->string (take (drop chars (unbox pos)) 4)))
     (unless (= (length hex) 4)
       (raise-err 'json "json.rkt"
                  (format "malformed JSON at position ~a: a \\u escape needs four hex digits" (unbox pos))))
     (set-box! pos (+ (unbox pos) 4))
     (define code (string->number hex 16))
     (unless code
       (raise-err 'json "json.rkt"
                  (format "malformed JSON at position ~a: ~a is not a hex number" (unbox pos) hex)))
     (loop (cons (integer->char code) out))]
    [else
     (raise-err 'json "json.rkt"
                (format "malformed JSON at position ~a: ~a is not an escape JSON knows" (unbox pos) c))]))

;; read-literal reads one of the three words JSON has — true, false and null —
;; and gives back the value it stands for.
(define (read-literal chars pos word value)
  (define tail (list->string (drop chars (unbox pos))))
  (unless (string-prefix? tail word)
    (raise-err 'json "json.rkt"
               (format "malformed JSON at position ~a: ~a is not a word JSON knows" (unbox pos) word)))
  (set-box! pos (+ (unbox pos) (string-length word)))
  value)

;; read-number reads a JSON number: an optional minus, then digits, then an
;; optional fraction and an optional exponent. A number with no fraction and no
;; exponent stays an exact integer, so 9 does not come back as 9.0.
(define (read-number chars pos)
  (define start (unbox pos))
  (when (and (< (unbox pos) (length chars)) (char=? (list-ref chars (unbox pos)) #\-))
    (set-box! pos (add1 (unbox pos))))
  (define digits (takef (lambda (c) (char-numeric? c)) (drop chars (unbox pos))))
  (set-box! pos (+ (unbox pos) (length digits)))
  (define text (list->string (take chars (- (unbox pos) start))))
  (when (string=? text "") (raise-err 'json "json.rkt" "malformed JSON: a number needs a digit"))
  (when (and (< (unbox pos) (length chars)) (char=? (list-ref chars (unbox pos)) #\.))
    (set-box! pos (add1 (unbox pos)))
    (define frac (takef (lambda (c) (char-numeric? c)) (drop chars (unbox pos))))
    (set-box! pos (+ (unbox pos) (length frac)))
    (set! text (list->string (take chars (- (unbox pos) start)))))
  (when (and (< (unbox pos) (length chars))
             (memv (list-ref chars (unbox pos)) '(#\e #\E)))
    (set-box! pos (add1 (unbox pos)))
    (when (and (< (unbox pos) (length chars))
               (memv (list-ref chars (unbox pos)) '(#\+ #\-)))
      (set-box! pos (add1 (unbox pos))))
    (define exp-digits (takef (lambda (c) (char-numeric? c)) (drop chars (unbox pos))))
    (set-box! pos (+ (unbox pos) (length exp-digits)))
    (set! text (list->string (take chars (- (unbox pos) start)))))
  (define number (string->number text))
  (unless number
    (raise-err 'json "json.rkt"
               (format "malformed JSON at position ~a: ~a is not a number" start text)))
  number)

;; json->text writes a JSON value as JSON text, with two spaces of indent and
;; one member or value on a line. The same value always gives the same text,
;; so a caller can compare two texts and know the values are the same.
(define (json->text value)
  (define out (open-output-string))
  (write-value out value 0)
  (get-output-string out))

;; write-value writes one value at the given depth of indent.
(define (write-value out value depth)
  (cond
    [(json-object? value) (write-object out value depth)]
    [(list? value) (write-array out value depth)]
    [(string? value) (write-string out value)]
    [(number? value) (display (number->json value) out)]
    [(boolean? value) (display (if value "true" "false") out)]
    [(json-null? value) (display "null" out)]
    [else
     (raise-err 'json "json.rkt"
                (format "~a is not a JSON value; the writer will not invent one" value))]))

;; write-object writes a JSON object: a { , one member per line, and a }.
;; The members are separated by a comma, and there is no comma after the last
;; one, because a comma after the last member is a member that is not there.
(define (write-object out obj depth)
  (define entries (json-object-entries obj))
  (if (null? entries)
      (display "{}" out)
      (begin
        (display "{" out)
        (for ([entry (in-list entries)] [index (in-naturals)])
          (unless (zero? index) (display "," out))
          (newline out)
          (indent out (add1 depth))
          (write-string out (car entry))
          (display ": " out)
          (write-value out (cdr entry) (add1 depth)))
        (newline out)
        (indent out depth)
        (display "}" out))))

;; write-array writes a JSON array: a [ , one value per line, and a ].
;; The values are separated by a comma, and there is no comma after the last
;; one, because a comma after the last value is a value that is not there.
(define (write-array out items depth)
  (if (null? items)
      (display "[]" out)
      (begin
        (display "[" out)
        (for ([item (in-list items)] [index (in-naturals)])
          (unless (zero? index) (display "," out))
          (newline out)
          (indent out (add1 depth))
          (write-value out item (add1 depth)))
        (newline out)
        (indent out depth)
        (display "]" out))))

;; indent writes the spaces that put the next thing at the right place.
(define (indent out depth)
  (for ([i (in-range (* 2 depth))]) (display " " out)))

;; write-string writes a quoted string, with the escapes JSON requires.
(define (write-string out text)
  (display "\"" out)
  (for ([c (in-list (string->list text))])
    (cond
      [(char=? c #\") (display "\\\"" out)]
      [(char=? c #\\) (display "\\\\" out)]
      [(char=? c #\newline) (display "\\n" out)]
      [(char=? c #\return) (display "\\r" out)]
      [(char=? c #\tab) (display "\\t" out)]
      [(char=? c #\backspace) (display "\\b" out)]
      [(char=? c #\page) (display "\\f" out)]
      [(< (char->integer c) 32) (display (format "\\u~a" (~r (char->integer c) #:min-width 4 #:pad-string "0")) out)]
      [else (display c out)]))
  (display "\"" out))

;; number->json writes a number the way JSON writes one: a whole number with
;; no dot after it, and a fraction only when the number really has one.
(define (number->json n)
  (cond
    [(exact-integer? n) (number->string n)]
    [(exact? n) (number->string (exact->inexact n))]
    [else (format "~a" n)]))

;; json-write-aiu writes a value as JSON text and answers it as a string, for
;; a caller that wants the text and not a printed line.
(define (json-write-aiu value)
  (json->text value))

;; The keywords a declaration may carry that the data area reads. A line whose
;; keyword is not one of these is content, not data.
(define data-keywords
  '(tags language style theme color format font level
         caption column cell row-id meta))

;; document->json turns a parsed document into the JSON value that stands for
;; it: an array holding one object per top-level block, in the order the
;; blocks appear.
;;
;; The page is the bytes of the file the document came from. The model carries
;; byte offsets and not text, so the words of a block are cut out of the page
;; with those offsets. The bytes are bytes and not a string on purpose: the
;; offsets are byte offsets, and a page with multibyte characters in it has
;; more bytes than characters.
(define (document->json o page-bytes)
  (blocks->json (outline->blocks o page-bytes)))

;; outline->blocks reads a document into the blocks that stand for it, in the
;; order they appear. A block is described as a list, so a caller may write it
;; back as a page or as JSON without this file being asked twice.
(define (outline->blocks o page-bytes)
  (for/list ([node (in-list (outline-nodes o))]
             #:when (block-node? node))
    (node->block node o page-bytes)))

;; node->block describes one block. What a block becomes depends on its name:
;; a title and a paragraph become their words, a heading becomes its level,
;; its number and its words, a table becomes its shape, and anything else
;; becomes a data block that holds its words as a string.
(define (node->block node o page-bytes)
  (define name (block-node-name node))
  (define words (block-words page-bytes node))
  (cond
    [(eq? name 'title) (list 'title words)]
    [(eq? name 'paragraph) (list 'paragraph words)]
    [(eq? name 'heading)
     (list 'heading (list 'level (heading-level-of node)
                          'number (or (number-at o (block-node-line node)) "")
                          'text words))]
    [(eq? name 'table) (list 'table (table->spec (read-table node)))]
    ;; A code block keeps its own name in the JSON, because a code block is
    ;; not the same thing as a data block: its body was never read as
    ;; notation, and that difference must survive the round trip.
    [(eq? name 'code) (list 'code words)]
    [else (list 'data words)]))

;; block-words gives back the words of a block: the lines between its start
;; line and its end line, with the declaration lines and the comment blocks
;; taken out. What is left is what the reader sees.
(define (block-words page-bytes node)
  (define text (node-text page-bytes node))
  (string-join (content-lines text) "\n"))

;; node-text gives back the text of a block, cut out of the page with the
;; block's own byte offsets.
(define (node-text page-bytes node)
  (define start (block-node-start node))
  (define end (block-node-end node))
  (if (and (bytes? page-bytes) (>= end start) (<= end (bytes-length page-bytes)))
      (bytes->string/utf-8 (subbytes page-bytes start end))
      ""))

;; content-lines takes the lines of a block and keeps the ones that are
;; content: the start line and the end line go, the declaration lines go, and
;; a comment block goes whole.
(define (content-lines text)
  (define lines (string-split text "\n" #:trim? #f))
  (define inner (if (and (pair? lines) (>= (length lines) 2))
                    (cdr (drop-right lines 1))
                    '()))
  (keep-content-lines inner #f))

;; keep-content-lines walks the lines of a block and keeps the content ones. A
;; line that opens a comment starts a comment block, and the lines until the
;; comment closes are content of the comment, not of the block.
(define (keep-content-lines lines in-comment?)
  (cond
    [(null? lines) '()]
    [else
     (define line (car lines))
     (cond
       [(and (not in-comment?) (string=? (string-trim line) "comment start"))
        (keep-content-lines (cdr lines) #t)]
       [(and in-comment? (string=? (string-trim line) "comment end"))
        (keep-content-lines (cdr lines) #f)]
       [(or in-comment? (declaration-line? line))
        (keep-content-lines (cdr lines) in-comment?)]
       [else (cons line (keep-content-lines (cdr lines) in-comment?))])]))

;; declaration-line? says whether a line is a declaration, which means the
;; word before its colon is a registered keyword.
(define (declaration-line? line)
  (define trimmed (string-trim line))
  ;; index-of walks a list, so the characters are asked for as a list.
  (define colon (index-of (string->list trimmed) #\:))
  (and colon
       (> colon 0)
       (member (string->symbol (substring trimmed 0 colon)) data-keywords)))

;; table->spec describes a table as data: its caption, its columns, its
;; header and its rows. A cell that is missing keeps that fact, so a JSON
;; reader can tell a missing value from an empty string.
(define (table->spec table)
  (list 'caption (data-table-caption table)
        'columns (for/list ([c (in-list (data-table-columns table))])
                   (list 'name (column-name c)
                         'type (symbol->string (column-type c))
                         'optional (column-optional? c)))
        'header (for/list ([cell (in-list (or (data-table-header table) '()))])
                   (list (table-cell-value cell) (table-cell-present? cell)))
        'rows (for/list ([row (in-list (data-table-rows table))])
                (list 'id (or (table-row-id row) "")
                      'cells (for/list ([cell (in-list (table-row-cells row))])
                                (list (table-cell-value cell) (table-cell-present? cell)))))))

;; blocks->json turns described blocks into the JSON value that stands for
;; them: an array holding one object per block, in order.
(define (blocks->json blocks)
  (for/list ([block (in-list blocks)])
    (block->json block)))

;; block->json turns one described block into one JSON object.
(define (block->json block)
  (define kind (first block))
  (define spec (second block))
  (define obj (json-object '()))
  (cond
    [(eq? kind 'title) (json-object-set! obj "title" spec)]
    [(eq? kind 'paragraph) (json-object-set! obj "paragraph" spec)]
    [(eq? kind 'heading)
     (json-object-set! obj "heading" (json-object '()))
     (define inner (json-object-ref obj "heading"))
     (json-object-set! inner "level" (spec-ref 'level spec 1))
     (json-object-set! inner "number" (spec-ref 'number spec ""))
     (json-object-set! inner "text" (spec-ref 'text spec ""))]
    [(eq? kind 'table)
     (json-object-set! obj "table" (table->json spec))]
    ;; A code block keeps its own key, so that a page that goes to JSON and
    ;; comes back still holds a code block and not a data block.
    [(eq? kind 'code) (json-object-set! obj "code" spec)]
    [else (json-object-set! obj "data" spec)])
  obj)

;; table->json turns a described table into a JSON object.
(define (table->json spec)
  (define obj (json-object '()))
  (json-object-set! obj "caption" (spec-ref 'caption spec #f))
  (json-object-set! obj "columns"
                    (for/list ([c (in-list (spec-ref 'columns spec '()))])
                      (let ([one (json-object '())])
                        (json-object-set! one "name" (spec-ref 'name c ""))
                        (json-object-set! one "type" (spec-ref 'type c "text"))
                        (json-object-set! one "optional" (spec-ref 'optional c #f))
                        one)))
  (json-object-set! obj "header" (spec-ref 'header spec '()))
  (json-object-set! obj "rows"
                    (for/list ([row (in-list (spec-ref 'rows spec '()))])
                      (let ([one (json-object '())])
                        (json-object-set! one "id" (spec-ref 'id row ""))
                        (json-object-set! one "cells"
                                          (for/list ([cell (in-list (spec-ref 'cells row '()))])
                                            (list (first cell) (second cell))))
                        one)))
  obj)

;; json->blocks turns a JSON value into described blocks: the other way
;; round. A JSON array of block objects comes back as blocks; anything else is
;; refused, because a reader must not guess what a lone number was meant to
;; be.
(define (json->blocks value)
  (unless (list? value)
    (raise-err 'json "json.rkt"
               "the JSON value is not an array of blocks; the AIU form of a document is an array, one object per block"))
  (for/list ([item (in-list value)])
    (json->block item)))

;; json->block turns one JSON object into one described block.
(define (json->block item)
  (unless (json-object? item)
    (raise-err 'json "json.rkt"
               "an item of the array is not an object; a block is written as an object with one key"))
  (define entries (json-object-entries item))
  (cond
    [(null? entries)
     (raise-err 'json "json.rkt" "a block object holds no key; a block says what it is")]
    [(string=? (car (car entries)) "title") (list 'title (cdr (car entries)))]
    [(string=? (car (car entries)) "paragraph") (list 'paragraph (cdr (car entries)))]
    [(string=? (car (car entries)) "heading")
     (define inner (cdr (car entries)))
     (list 'heading (list 'level (json-ref inner "level" 1)
                          'number (json-ref inner "number" "")
                          'text (json-ref inner "text" "")))]
    [(string=? (car (car entries)) "table")
     (list 'table (json->table-spec (cdr (car entries))))]
    [(string=? (car (car entries)) "code") (list 'code (cdr (car entries)))]
    [(string=? (car (car entries)) "data") (list 'data (cdr (car entries)))]
    [else
     (raise-err 'json "json.rkt"
                (format "~a is not a key a block may hold; the keys are title, paragraph, heading, table, code and data"
                        (car (car entries))))]))

;; json->table-spec turns a JSON table object into a described table.
(define (json->table-spec obj)
  (list 'caption (json-ref obj "caption" #f)
        'columns (for/list ([c (in-list (json-ref obj "columns" '()))])
                   (list 'name (json-ref c "name" "")
                         'type (json-ref c "type" "text")
                         'optional (json-ref c "optional" #f)))
        'header (json-ref obj "header" '())
        'rows (for/list ([row (in-list (json-ref obj "rows" '()))])
                (list 'id (json-ref row "id" "")
                      'cells (for/list ([cell (in-list (json-ref row "cells" '()))])
                                (list (if (and (pair? cell) (pair? (cdr cell))) (car cell) "")
                                      (if (and (pair? cell) (pair? (cdr cell))) (cadr cell) #f)))))))

;; json-ref reads one key of a JSON object, or answers the fallback when the
;; object does not hold it.
(define (json-ref obj key fallback)
  (define found (and (json-object? obj) (json-object-ref obj key)))
  (if found found fallback))

;; spec-ref reads one field of a described block or a described table. The spec
;; is a flat list of key and value, so the key is looked for by walking the
;; list and the value is what follows it. A key that is not there gives the
;; fallback, because a field the description does not carry is an absence and
;; not a failure.
(define (spec-ref key spec fallback)
  (cond
    [(not (list? spec)) fallback]
    [(null? spec) fallback]
    [(eq? (car spec) key)
     (if (null? (cdr spec)) fallback (cadr spec))]
    [else (spec-ref key (cdr spec) fallback)]))
