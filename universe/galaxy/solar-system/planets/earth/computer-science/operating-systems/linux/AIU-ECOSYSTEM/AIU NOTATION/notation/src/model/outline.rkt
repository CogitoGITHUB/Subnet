#lang racket/base
;; One job: the tree built from parsed elements.
;; Registered in plan/package-tree.org (model/outline.rkt). Lands with TODO
;; item 3.
;;
;; It reads a parse-tree-document (join/INDEX.org) — the plain text the Rust
;; parser printed — and builds the node tree. It reads only the shape frozen in
;; join/INDEX.org, so the two sides cannot drift without one of them failing.

(require "nodes.rkt"
         "../errors/raise.rkt")

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
  (define nodes '())
  (define ended? #f)
  (let loop ([rest (cdr lines)])
    (cond
      [(null? rest) 'done]
      [ended? 'done]
      [else
       (define line (car rest))
       (cond
         [(string=? line "")
          (loop (cdr rest))]
         [(string=? line "end")
          (set! ended? #t)
          (loop (cdr rest))]
         [(string-prefix? (string-trim line) "file ")
          (set! file-path (unquote-field (string-trim (substring line 5))))
          (loop (cdr rest))]
         [(string-prefix? (string-trim line) "node ")
          (set! nodes (cons (parse-node-line (string-trim line)) nodes))
          (loop (cdr rest))]
         [(string-prefix? (string-trim line) "error ")
          (set! nodes (cons (parse-error-line (string-trim line)) nodes))
          (loop (cdr rest))]
         [else
          ;; decl and any future line type are carried inside their node; a
          ;; line the shape does not define is not silently dropped.
          (raise-err 'outline "outline.rkt"
                     (format "the document holds a line this shape does not define: ~a" line))])]))
  (when (not ended?)
    (raise-err 'outline "outline.rkt"
               "the document has no end line; it is truncated, so the tree is not whole"))
  (outline 1 file-path (reverse nodes)))

;; parse-node-line reads "node block <name> <line> <start> <endLine> <end> <depth>".
(define (parse-node-line line)
  (define parts (string-split line " " #:trim? #t #:repeat? #t))
  (block-node (string->symbol (list-ref parts 2))
              (string->number (list-ref parts 3))
              (string->number (list-ref parts 4))
              (string->number (list-ref parts 6))
              '()
              '()))

;; parse-error-line reads
;; "error <kind> <line> <offset> <openerLine> \"<what>\" \"<whatToDo>\"".
(define (parse-error-line line)
  (define parts (string-split line " " #:trim? #t #:repeat? #t))
  (error-node (list-ref parts 1)
              (string->number (list-ref parts 2))
              (string->number (list-ref parts 3))
              (let ([o (string->number (list-ref parts 4))]) (if (= o 0) #f o))
              (unquote-field (list-ref parts 5))
              (unquote-field (list-ref parts 6))))

;; unquote-field reads a quoted field: the quotes come off and a doubled quote
;; inside becomes one quote (join/INDEX.org, "Quoting").
(define (unquote-field field)
  (define s (if (and (> (string-length field) 1)
                    (char=? (string-ref field 0) #\")
                    (char=? (string-ref field (- (string-length field) 1)) #\"))
               (substring field 1 (- (string-length field) 1))
               field))
  (define out (open-output-string))
  (define chars (string->list s))
  (let loop ([i 0])
    (when (< i (length chars))
      (if (and (char=? (list-ref chars i) #\") (< (+ i 1) (length chars))
               (char=? (list-ref chars (+ i 1)) #\"))
          (begin (write-char out #\") (loop (+ i 2)))
          (begin (write-char out (list-ref chars i)) (loop (+ i 1))))))
  (get-output-string out))

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