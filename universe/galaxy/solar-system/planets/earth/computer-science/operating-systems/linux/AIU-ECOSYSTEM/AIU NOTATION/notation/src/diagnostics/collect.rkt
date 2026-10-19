#lang racket/base
;; One job: gather every finding a reader must be told, in tree order.
;; Registered in plan/package-tree.org (diagnostics/collect.rkt). Lands with
;; TODO item 5 (build-order step 4).
;;
;; A finding is data, never a printed line. It carries WHO (the file it is
;; about), WHERE (the 1-based line and the 1-based character column — the
;; pair the text area produces), WHAT (what is wrong, one sentence) and
;; WHAT TO DO (what the reader can do about it). What to do is never empty:
;; an error that cannot say what to do is not an error yet (join/INDEX.org).
;;
;; This file prints nothing and never waits. Reading a tree in memory does
;; not block, so the wait door stays shut and narration/ is not used here:
;; rule 1.1 keeps a block from being silent, not a walk. Every finding is
;; rendered by report.rkt through errors/render.rkt, the only printer of an
;; error in the package — a collector that printed would be a second one.

(require racket/list
         racket/string
         "../errors/raise.rkt"
         "../elements/literals.rkt"
         "../elements/register.rkt"
         "../model/nodes.rkt"
         "../model/outline.rkt"
         "../model/properties.rkt")

(provide collect-findings finding-kinds (struct-out finding))


;; One finding. kind says which check found it; who, line and column say where
;; in the file it is; what and what-to-do say what is wrong and what the
;; reader may do about it. A line of 0 or a column of 0 means the position
;; is not known — never that it is the first one.
(struct finding (kind who line column what what-to-do) #:transparent)

;; The five kinds of finding, named here so a caller may count or filter on
;; them without matching words inside a sentence.
(define finding-kinds
  '(unknown-element-name
    tag-names-nothing
    property-no-value
    link-no-target
    parser-recovery))

;; link is the keyword a link declaration carries. A link is not a property:
;; a property is a hint for a reader, and a link names a target. The parser
;; does not know the keyword yet — rule B registers tags, language, style,
;; theme, color, format and font — so no page can carry a link today and the
;; link check stays quiet. Registering "link" is the owner's decision (see
;; plan/package-tree.org, "Declaration keywords"); this file already reads the
;; shape, so nothing here changes when that decision lands.
(define link-keyword 'link)

;; collect-findings walks an outline and returns every finding in tree order:
;; each recovered parser error and each model problem where it sits. page is
;; the source text the document's offsets index into, or #f when the caller
;; holds only the parse-tree-document; without the page no column can be
;; counted, and every finding's column is 0, which the report prints as
;; "unknown".
(define (collect-findings page o)
  (define who (or (outline-file o) "the document"))
  (define lines (page-lines page))
  (define targets (link-targets who (outline-nodes o)))
  (append-map (lambda (n) (walk-node lines who targets n)) (outline-nodes o)))

;; walk-node reads one node and then its children, so a reader meets the
;; findings of a block before the findings of what is inside it.
(define (walk-node lines who targets n)
  (cond
    [(error-node? n) (list (recovered-finding lines who n))]
    [(block-node? n)
     (append (walk-block lines who targets n)
             (append-map (lambda (c) (walk-node lines who targets c))
                         (block-node-children n)))]
    [else
     ;; A node kind this walk does not know is refused, not skipped: a
     ;; finding nobody was told about is worse than a refusal.
     (raise-err 'collect "collect.rkt"
                (format "~a is not a node; the walk reads blocks and error nodes"
                        n))]))

;; walk-block reads one block: first the name the table must know, then every
;; declaration written under its start line, in the order written.
(define (walk-block lines who targets n)
  (define line (block-node-line n))
  (define column (column-at lines line (block-node-start n)))
  (append
   (if (known-name? (block-node-name n))
       '()
       (list (finding 'unknown-element-name who line column
                      (format "the block named ~a is not a registered block name; the table knows ~a"
                              (block-node-name n) (element-names))
                      (format "write one of ~a, or ask for ~a to be registered"
                              (element-names) (block-node-name n)))))
   (append-map (lambda (d) (walk-declaration lines who targets d))
               (block-node-declarations n))))

;; walk-declaration reads one declaration. A declaration reaches this file as
;; the four fields of the document's declaration line, in order — keyword,
;; value, line, byte offset (join/INDEX.org) — so a finding can name where
;; the declaration itself is. Any other shape is refused rather than guessed;
;; model/outline.rkt is the file that must fill block-node-declarations with
;; this shape, and it does not yet, so the declaration findings below stay
;; quiet today and fire the day it does.
(define (walk-declaration lines who targets d)
  (unless (and (list? d) (= (length d) 4))
    (raise-err 'collect "collect.rkt"
               "a declaration is not its four fields — keyword, value, line, offset — so this file will not guess which is which"))
  (define keyword (list-ref d 0))
  (define value (list-ref d 1))
  (define line (list-ref d 2))
  (define column (column-at lines line (list-ref d 3)))
  (cond
    [(eq? keyword link-keyword) (walk-link who targets value line column)]
    [(memq keyword property-keywords)
     (walk-property who keyword value line column)]
    [else
     ;; A keyword nobody registered is refused, never read, so that no file
     ;; may invent a property (model/properties.rkt refuses the same way).
     (raise-err 'collect "collect.rkt"
                (format "~a is not a registered declaration keyword; use one of ~a"
                        keyword property-keywords))]))

;; walk-property reads one property declaration. An empty value is a finding
;; of its own: the declaration is there and says nothing, so the reader is
;; told rather than left with a line that looks as if it meant something.
(define (walk-property who keyword value line column)
  (if (string=? (string-trim value) "")
      (list (finding 'property-no-value who line column
                     (format "the ~a declaration has no value" keyword)
                     (format "write a value after the colon, or take the ~a line away"
                             keyword)))
      (if (eq? keyword 'tags)
          (walk-tags who value line column)
          '())))

;; walk-tags reads a tags declaration. A tag names the file it sits in
;; (syntax/file-identity.org), so the one way a tag can name nothing is to
;; stop being a name at all: a word carrying punctuation cannot be searched
;; for, typed on a phone keyboard or matched later. Resolving a tag against
;; other files is not decided yet and belongs to references/ when it lands.
(define (walk-tags who value line column)
  (append-map
   (lambda (word)
     (if (literal-name? word)
         '()
         (list (finding 'tag-names-nothing who line column
                        (format "the tag ~a is not a name; a tag is letters and dashes"
                                word)
                        "write one tag per word, letters and dashes only"))))
   (parse-tags value)))

;; walk-link reads a link declaration. A link carries one target: the file
;; itself, or a block inside it. A link naming neither is a finding, because
;; a reader who follows it arrives nowhere.
(define (walk-link who targets value line column)
  (define target (string-trim value))
  (if (member target targets)
      '()
      (list (finding 'link-no-target who line column
                     (format "the link names ~a, which is not in this document"
                             (named-target target))
                     (format "point the link at the file or at a block of it; the document holds ~a"
                             targets)))))

;; named-target says an empty target in words, so the sentence above reads the
;; same whether the link names something or nothing.
(define (named-target target)
  (if (string=? target "") "<nothing>" target))

;; link-targets lists what a link may point at: every block name in the tree
;; and the file itself, as the document's file line wrote it. That is what
;; "names something" means inside one document; nothing here reaches outside.
(define (link-targets who nodes)
  (append (block-names nodes) (list who)))

;; block-names walks the tree and lists every block name, as the strings a
;; link target is written with.
(define (block-names nodes)
  (append-map
   (lambda (n)
     (if (block-node? n)
         (cons (symbol->string (block-node-name n))
               (block-names (block-node-children n)))
         '()))
   nodes))

;; recovered-finding is the finding a parser error node becomes. The kind, the
;; what and the what to do are the parser's own words, so the reader is told
;; exactly what was recovered and what to do about it — every stray-text error
;; included, which is what plan/package-tree.org registers this file for. The
;; frozen shape says whatToDo is always filled; this file does not invent one
;; when it is not.
(define (recovered-finding lines who n)
  (finding 'parser-recovery who (error-node-line n)
           (column-at lines (error-node-line n) (error-node-offset n))
           (format "the parser recovered from ~a: ~a"
                   (error-node-kind n) (error-node-what n))
           (error-node-what-to-do n)))

;; page-lines splits the page once, so every column is counted against the
;; same lines. With no page there is nothing to count against and every
;; column stays 0.
(define (page-lines page)
  (if page (string-split page "\n" #:trim? #f) #f))

;; column-at is this side of the text area: a byte offset becomes the
;; 1-based character column on a known 1-based line. It answers 0 when there
;; is no page, no such line, or an offset lying before that line — a column is
;; counted or it is unknown, never guessed.
(define (column-at lines line offset)
  (if (or (not lines) (< line 1) (> line (length lines)) (< offset 0))
      0
      (add1 (chars-before-byte (list-ref lines (- line 1))
                               (- offset (bytes-before-line lines line))))))

;; bytes-before-line counts the bytes of every line before the given one, each
;; with its newline, because an offset indexes bytes (join/INDEX.org).
(define (bytes-before-line lines line)
  (let loop ([i 1] [at 0])
    (cond
      [(= i line) at]
      [else (loop (add1 i) (+ at (bytes-of-line (list-ref lines (- i 1)))))])))

;; bytes-of-line counts one line and the newline after it.
(define (bytes-of-line l)
  (+ 1 (bytes-length (string->bytes/utf-8 l))))

;; chars-before-byte counts the characters held by the first n bytes of a
;; line. Offsets are bytes and columns are characters, so the two are counted
;; apart here and nowhere else (syntax/first-slice-freeze.org, rule F).
(define (chars-before-byte l n)
  (let loop ([cs (string->list l)] [bytes 0] [chars 0])
    (cond
      [(or (null? cs) (>= bytes n)) chars]
      [else
       (loop (cdr cs)
             (+ bytes (bytes-length (string->bytes/utf-8 (string (car cs)))))
             (add1 chars))])))