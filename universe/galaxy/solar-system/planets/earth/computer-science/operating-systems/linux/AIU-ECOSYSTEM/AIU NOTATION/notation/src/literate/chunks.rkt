#lang racket/base
;; One job: named chunks and their graph.
;; Registered in plan/package-tree.org (literate/chunks.rkt). Lands with TODO
;; item 6 (build step 5, literate code).
;;
;; A chunk is a code block that says its own name:
;;
;;   code start
;;   chunk: build-the-index
;;   into: plan/FILE-INVENTORY.org
;;   depends: read-the-nodes
;;   <the code itself, line for line>
;;   code end
;;
;; The three keyword lines at the top are the chunk's header and are not part
;; of the source it sends; everything after them is source, kept byte for byte.
;; A code block with no chunk: line is an ordinary code block and is left
;; alone: it is content, not work.
;;
;; Three frozen rules decide this file, and none of them is mine:
;;   - rule B (syntax/first-slice-freeze.org): a declaration is a hint, never
;;     meaning. So chunk, into and depends decide what a run sends, never what
;;     a reader reads.
;;   - rule D: a code block's body is opaque to the parser. Those bytes belong
;;     to this area, which is why the body is read here and nowhere else.
;;   - rule A: only an exact matching end line closes a block, so where the
;;     body ends is found by that same rule and never guessed.
;;
;; The header keywords chunk, into and depends are NOT in the registered
;; declaration list (rule B names tags, language, style, theme, color, format
;; and font). Registering them is the owner's decision and is recorded as
;; still open; until it is taken they are read from inside the opaque body,
;; where no registered keyword is involved and rule B is not touched.
;;
;; Narration: one step line, because this file reads a page the caller already
;; holds and runs nothing in it (the discipline diagnostics/collect.rkt sets).
;; There is no wait in this file: it touches no disk, so nothing here can
;; block, and a wait door with nothing to wait for is noise.

(require racket/list
         racket/port
         racket/string
         "../elements/dispatch.rkt"
         "../elements/literals.rkt"
         "../errors/raise.rkt"
         "../model/nodes.rkt"
         "../model/outline.rkt"
         "../model/properties.rkt"
         "../narration/narration.rkt")

(provide read-chunks read-chunk-graph chunk-names chunk-for chunk-dependencies
         chunk-line (struct-out chunk) (struct-out chunk-graph))


;; A chunk: the name it declares, the code block it sits on, the source loaded
;; out of that block, the names it depends on, and the into: value as written.
(struct chunk (name node source depends into) #:transparent)

;; The graph: which document, which chunks, and every edge between them. An
;; edge is written (from . to) and is declared, not found: an edge to a name no
;; chunk carries stays in the graph so that scan.rkt can report it here rather
;; than have it disappear quietly.
(struct chunk-graph (file chunks edges) #:transparent)

;; The header keywords this area reads, named once so that no second file
;; decides what a chunk header is. See the header note: these three are not yet
;; registered declaration keywords, and registering them is the owner's call.
(define chunk-header-keywords '(chunk into depends))


;; read-chunks reads every chunk in a document. page is the source text the
;; document's line numbers index into, and nothing in it is run.
(define (read-chunks o page)
  (define blocks (filter opaque-block? (outline-nodes o)))
  (say-step "reading the chunks"
            (format "~a code block(s) in ~a, read for a chunk name; nothing was run"
                    (length blocks)
                    (or (outline-file o) "a document with no file name")))
  (define lines (page-lines page))
  (filter values (map (lambda (n) (chunk-in-block lines n)) blocks)))

;; opaque-block? says a node is a block the parser does not read inside. It
;; asks the one name-to-meaning door (elements/dispatch.rkt) instead of
;; matching the word "code", so the host of a chunk is decided by the register
;; and not by a word written again here.
(define (opaque-block? n)
  (and (block-node? n)
       (opaque? (symbol->string (block-node-name n)))))

;; chunk-in-block reads one code block and answers the chunk it holds, or #f
;; when the block names none. The source is joined back with the newline that
;; was cut on, so the text is the bytes the page holds (rule F).
(define (chunk-in-block lines node)
  (define body-start (+ (block-node-line node) 1))
  (define body-end (chunk-end-line lines node body-start))
  (define body (lines-between lines body-start (sub1 body-end)))
  (define parts (take-header body))
  (define header (car parts))
  (define source (cdr parts))
  (cond
    [(not (assq 'chunk header)) #f]
    [else
     (chunk (chunk-name-of (cdr (assq 'chunk header)) node)
            node
            (string-join source "\n")
            (chunk-depends-of header)
            (chunk-into-of header))]))

;; chunk-end-line finds the line where the block opened on this node closes.
;; Rule A decides it: only an exact matching end line closes a block.
(define (chunk-end-line lines node body-start)
  (define wanted (symbol->string (block-node-name node)))
  (define found
    (for/first ([i (in-range (sub1 body-start) (length lines))])
      (define line (list-ref lines i))
      (and (end-line? line)
           (string=? (name-of line) wanted)
           (add1 i))))
  (unless found
    (raise-err 'chunks "chunks.rkt"
               (format "the code block that starts on line ~a has no matching \"~a end\" line; its body cannot be read"
                       (block-node-line node) wanted)))
  (check-end-offset lines node found)
  found)

;; check-end-offset compares the walk with what the tree already knows: a node
;; entry carries the end byte offset (join/INDEX.org). When the two disagree
;; the run says so and keeps the walk's answer, because the frozen matching
;; rule is the one the parser followed too. A CR LF page is skipped: its bytes
;; do not line up with its lines, and a comparison that cannot be true must not
;; be reported as a failure.
(define (check-end-offset lines node line)
  (cond
    [(for/or ([l lines]) (string-contains? l "\r"))
     (say-note (format "the end of the block on line ~a" line)
               "this page ends its lines with CR LF, so its bytes do not line up with its lines; the end comes from the rule alone")]
    [else
     (define walked (line-start-offset lines line))
     (define known (block-node-end node))
     (unless (= walked known)
       (say-warn (format "the block that ends on line ~a" line)
                 (format "the tree ends it at byte ~a and the rule at byte ~a; the source was cut by the rule, and the difference is the reader's to judge"
                         known walked)))]))

;; line-start-offset counts the bytes before a 1-based line: every earlier line
;; plus the newline that ends it. Offsets are bytes, lines are UTF-8 text
;; (rule F).
(define (line-start-offset lines line)
  (for/fold ([n 0]) ([l (take lines (sub1 line))])
    (+ n (string-utf-8-length l) 1)))

;; page-lines splits the page into its lines. Empty lines are kept and the CR
;; of a CR LF page stays on the line it belongs to, so a cut and a join give
;; back the same bytes (rule F).
(define (page-lines page)
  (string-split page "\n" #:trim? #f #:repeat? #f))

;; lines-between returns the 1-based lines first through last, and never walks
;; past the end of the page it was given.
(define (lines-between lines first-line last-line)
  (for/list ([i (in-range (sub1 first-line) (sub1 last-line))]
             #:when (< i (length lines)))
    (list-ref lines i)))

;; take-header splits a body into its header and its source: the header is the
;; run of keyword lines at the very top, and the source is every line after
;; them, untouched. A keyword line that comes after a line of source is
;; source, because the header is the head of the block or it is nothing. The
;; answer is (header source), where header is a list of (keyword . value).
(define (take-header body)
  (let loop ([left body] [header '()])
    (define line (if (null? left) "" (car left)))
    (define kw (header-keyword line))
    (cond
      [(or (null? left) (not kw)) (cons (reverse header) left)]
      [(assq kw header)
       (raise-err 'chunks "chunks.rkt"
                  (format "the chunk names ~a twice; a header says each thing once" kw))]
      [else
       (loop (cdr left) (cons (cons kw (header-value line)) header))])))

;; string-index finds the 0-based index of character ch in str, or #f if not found.
(define (string-index str ch)
  (for/first ([c (in-string str)] [i (in-naturals)] #:when (char=? c ch)) i))

;; header-keyword reads the keyword of a header line, or #f when the line is
;; not one of this area's declarations. The keyword ends at the first colon,
;; which is where rule B puts it, and it must be one this area registered.
(define (header-keyword line)
  (define colon (string-index line #\:))
  (and colon
       (let ([kw (string->symbol (string-trim (substring line 0 colon)))])
         (and (memq kw chunk-header-keywords) kw))))

;; header-value is what follows the colon, with the space after it removed.
(define (header-value line)
  (string-trim (substring line (add1 (string-index line #\:)))))

;; chunk-name-of holds a chunk name to the one rule the package already has:
;; a literal name (elements/literals.rkt), so a name that may be typed on a
;; phone and quoted in a message is the same name everywhere.
(define (chunk-name-of value node)
  (unless (literal-name? value)
    (raise-err 'chunks "chunks.rkt"
               (format "the chunk on line ~a is named \"~a\", which is not a name; a name is a lowercase word with dashes, such as build-the-index"
                       (block-node-line node) value)))
  value)

;; chunk-depends-of reads the names a chunk declares it depends on. They are
;; separated by spaces and split with the one splitter properties.rkt has, so
;; no file in the package grows a second way to read a word list.
(define (chunk-depends-of header)
  (define entry (assq 'depends header))
  (if entry (parse-tags (cdr entry)) '()))

;; chunk-into-of keeps the target as the document wrote it. Reading it is
;; targets.rkt's one job, and nothing here guesses what it means.
(define (chunk-into-of header)
  (define entry (assq 'into header))
  (if entry (cdr entry) #f))

;; chunk-line is the line the chunk's block opens on, so a message points at
;; the place in the document instead of at the chunk in general.
(define (chunk-line c)
  (block-node-line (chunk-node c)))

;; read-chunk-graph reads the chunks and the edges between them.
(define (read-chunk-graph o page)
  (define chunks (read-chunks o page))
  (chunk-graph (outline-file o) chunks (chunk-edges chunks)))

;; chunk-edges lists every declared edge, from the chunk that declared it to
;; the name it declared. Order is the order the chunks were read in.
(define (chunk-edges chunks)
  (append-map (lambda (c)
                (map (lambda (d) (cons (chunk-name c) d)) (chunk-depends c)))
              chunks))

;; chunk-names lists the names in reading order, which is the order the page
;; was written in. The order chunks are sent in is scan.rkt's job.
(define (chunk-names graph)
  (map chunk-name (chunk-graph-chunks graph)))

;; chunk-for finds one chunk by name, which is how a send says which chunk it
;; means. It answers #f for a name nothing carries; it never guesses.
(define (chunk-for graph name)
  (for/first ([c (in-list (chunk-graph-chunks graph))]
              #:when (equal? (chunk-name c) name))
    c))

;; chunk-dependencies lists the names one chunk declares, in the order it
;; declares them. A name no chunk carries is kept: an unknown dependency is
;; something to report, not something to drop here.
(define (chunk-dependencies graph name)
  (define c (chunk-for graph name))
  (if c (chunk-depends c) '()))
