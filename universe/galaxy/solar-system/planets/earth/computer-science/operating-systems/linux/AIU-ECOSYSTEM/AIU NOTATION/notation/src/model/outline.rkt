#lang racket/base
;; One job: the tree built from parsed elements.
;; Registered in plan/package-tree.org (model/outline.rkt). Lands with TODO
;; item 3.
;;
;; It reads a parse-tree-document (join/INDEX.org) — the plain text the Rust
;; parser printed — and builds the node tree. It reads only the shape frozen in
;; join/INDEX.org, so the two sides cannot drift without one of them failing.
;;
;; Three things happen here and nowhere else: the declarations are attached to
;; the block they were written in, the children are put under the block they
;; belong to, and the tree prints back in the shape it came in.
;;
;; The depth field is what puts a child under its parent, so the reader counts
;; nothing: a node at depth 0 is a root, a node at depth 1 is a child of the
;; root above it, and so on.

(require racket/string
         "nodes.rkt"
         "../errors/raise.rkt")

(provide read-outline outline-errors outline-document (struct-out outline) document-header)


(struct outline (version file nodes) #:transparent)

;; The frozen header. A document that does not start with it is refused, never
;; guessed at.
(define document-header "NOTATION-DOCUMENT 1")

;; read-outline parses a document text into an outline.
(define (read-outline text)
  (define lines (string-split text "\n" #:trim? #f))
  (when (or (null? lines) (not (string=? (car lines) document-header)))
    (raise-err 'outline "outline.rkt"
               "the document does not start with NOTATION-DOCUMENT 1; refusing to guess the shape"))
  (define file-path #f)
  ;; The blocks that are still open, outermost first. A node line says how
  ;; deep it sits, so the reader knows which open block it belongs to without
  ;; counting anything.
  (define open '())
  (define roots '())
  ;; The block a declaration line belongs to: the one that was read just before
  ;; it. The Rust writer prints a block's declarations right after the block's
  ;; own line, so the block just read is the block the declaration is in.
  (define current #f)
  (define ended? #f)
  (let loop ([rest (cdr lines)])
    (cond
      [(null? rest) 'done]
      [ended? 'done]
      [else
       (define line (car rest))
       (cond
         [(string=? line "") (loop (cdr rest))]
         [(string=? line "end") (set! ended? #t) (loop (cdr rest))]
         [(string-prefix? (string-trim line) "file ")
          (set! file-path (unquote-field (string-trim (substring line 5))))
          (loop (cdr rest))]
         [(string-prefix? (string-trim line) "node ")
          (define n (parse-node-line (string-trim line)))
          (set! current n)
          ;; The blocks at or below this depth are closed: a node at depth 0
          ;; is a sibling of the block above it, not its child.
          (set! open (keep-blocks-above open (block-node-depth n)))
          (if (null? open)
              (set! roots (cons n roots))
              (add-child! (car open) n))
          (set! open (cons n open))
          (loop (cdr rest))]
         [(string-prefix? (string-trim line) "error ")
          ;; An error line carries no depth of its own, so it belongs to the
          ;; innermost block that is still open — the block whose body it was
          ;; found in. The Rust parser puts an error in the innermost open
          ;; block too, so the two agree.
          (define e (parse-error-line (string-trim line)))
          (set! current #f)
          (if (null? open)
              (set! roots (cons e roots))
              (add-child! (car open) e))
          (loop (cdr rest))]
         [(string-prefix? (string-trim line) "decl ")
          ;; A declaration belongs to the block that was read just before it.
          (unless (and current (block-node? current))
            (raise-err 'outline "outline.rkt"
                       (format "a declaration line follows no block: ~a" line)))
          (add-declaration! current (parse-declaration-line (string-trim line)))
          (loop (cdr rest))]
         [else
          ;; A line the shape does not define is not silently dropped.
          (raise-err 'outline "outline.rkt"
                     (format "the document holds a line this shape does not define: ~a" line))])]))
  (when (not ended?)
    (raise-err 'outline "outline.rkt"
               "the document has no end line; it is truncated, so the tree is not whole"))
  (outline 1 file-path (reverse roots)))

;; keep-blocks-above keeps the open blocks that are shallower than the depth
;; given, dropping the ones at that depth or deeper. Those are closed: the
;; node just read is their sibling, not their child. The list stays innermost
;; first, so its head is the block a new node belongs inside.
(define (keep-blocks-above open depth)
  (for/list ([b (in-list open)]
             #:when (< (node-depth b) depth))
    b))

;; add-child! puts a node inside a block.
(define (add-child! block child)
  (set-block-node-children! block (append (block-node-children block) (list child))))

;; add-declaration! puts a declaration inside the block it was written in.
(define (add-declaration! block decl)
  (set-block-node-declarations! block (append (block-node-declarations block) (list decl))))

;; parse-node-line reads "node block <name> <startLine> <startOffset> <endLine>
;; <endOffset> <depth>". The name is a symbol, because the registered block
;; names are symbols.
(define (parse-node-line line)
  (define fields (split-fields line))
  (when (< (length fields) 8)
    (raise-err 'outline "outline.rkt"
               (format "a node line is not its eight fields: ~a" line)))
  (block-node (string->symbol (list-ref fields 2))
              (string->number (list-ref fields 3))
              (string->number (list-ref fields 4))
              (string->number (list-ref fields 5))
              (string->number (list-ref fields 6))
              (string->number (list-ref fields 7))
              '()
              '()))

;; parse-declaration-line reads "decl <keyword> <value> <line> <offset>". The
;; keyword becomes a symbol, because that is what the registered keyword names
;; are. The value is a quoted field, so the quotes come off it and the spaces
;; inside it stay.
(define (parse-declaration-line line)
  (define fields (split-fields line))
  (when (< (length fields) 5)
    (raise-err 'outline "outline.rkt"
               (format "a declaration line is not its five fields: ~a" line)))
  (list (string->symbol (list-ref fields 1))
        (unquote-field (list-ref fields 2))
        (string->number (list-ref fields 3))
        (string->number (list-ref fields 4))))

;; parse-error-line reads
;; "error <kind> <line> <offset> <openerLine> \"<what>\" \"<whatToDo>\"".
(define (parse-error-line line)
  (define fields (split-fields line))
  (when (< (length fields) 7)
    (raise-err 'outline "outline.rkt"
               (format "an error line is not its seven fields: ~a" line)))
  (error-node (list-ref fields 1)
              (string->number (list-ref fields 2))
              (string->number (list-ref fields 3))
              (let ([o (string->number (list-ref fields 4))]) (if (= o 0) #f o))
              (unquote-field (list-ref fields 5))
              (unquote-field (list-ref fields 6))))

;; split-fields splits a document line into its fields. A field in double
;; quotes is one field and keeps the spaces inside it, because the frozen
;; shape writes a value that has spaces as one quoted field (join/INDEX.org,
;; "Quoting"). A doubled quote inside a quoted field is one quote in the
;; value, and the closing quote is the one that is not doubled.
(define (split-fields line)
  (define chars (string->list line))
  (define len (length chars))
  (define (scan i in-quote? field fields)
    (cond
      [(>= i len) (reverse (if (string=? field "") fields (cons field fields)))]
      [else
       (define c (list-ref chars i))
       (cond
         [(and in-quote? (char=? c #\")
               (< (add1 i) len) (char=? (list-ref chars (add1 i)) #\"))
          ;; A doubled quote inside a quoted field is one quote in the value.
          (scan (+ i 2) in-quote? (string-append field "\"") fields)]
         [(and in-quote? (char=? c #\"))
          ;; The closing quote of a quoted field. The quotes stay, because
          ;; unquote-field is the one that takes them off.
          (scan (add1 i) #f (string-append field "\"") fields)]
         [(and (not in-quote?) (char=? c #\"))
          ;; The opening quote of a quoted field.
          (scan (add1 i) #t (string-append field "\"") fields)]
         [(and (not in-quote?) (char=? c #\space))
          (scan (add1 i) in-quote? "" (cons field fields))]
         [else
          (scan (add1 i) in-quote? (string-append field (string c)) fields)])]))
  (scan 0 #f "" '()))

;; unquote-field reads a quoted field: the quotes come off and a doubled quote
;; inside becomes one quote (join/INDEX.org, "Quoting").
(define (unquote-field field)
  (define trimmed (string-trim field))
  (define inner
    (if (and (>= (string-length trimmed) 2)
             (string=? (substring trimmed 0 1) "\"")
             (string=? (substring trimmed (sub1 (string-length trimmed))
                                  (string-length trimmed))
                       "\""))
        (substring trimmed 1 (sub1 (string-length trimmed)))
        trimmed))
  (regexp-replace* #rx"\"\"" inner "\""))

;; outline-errors lists the error nodes in the tree, in order.
(define (outline-errors o)
  (filter error-node? (outline-nodes o)))

;; outline-document prints the tree back as a parse-tree-document, so the model
;; never needs a second shape for the same thing.
(define (outline-document o)
  (string-append
   (string-append document-header "\n")
   (string-append "file \"" (or (outline-file o) "") "\"\n")
   (string-append
    (apply string-append
           (map (lambda (n) (node->document n 0)) (outline-nodes o)))
    "end\n")))
