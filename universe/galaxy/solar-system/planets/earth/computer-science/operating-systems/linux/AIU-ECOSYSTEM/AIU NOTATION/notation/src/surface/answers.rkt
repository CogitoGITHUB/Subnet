#lang racket/base
;; One job: the surface document — the frozen text an editor reads, and the
;; loader that reads that text back into facts.
;; Registered in plan/package-tree.org (surface/answers.rkt). Lands with TODO
;; item 8 (build step 7, the engine surface).
;;
;; This file is the boundary in words for a caller that is not Racket and does
;; not run this notation. It is the same idea as the parse-tree-document frozen
;; in join/INDEX.org — plain text, one line per fact, UTF-8, a newline after the
;; last line — and a different shape, because this one is written for the
;; editor's notation mode and not for the meaning side.
;;
;;   NOTATION-SURFACE 1
;;   file "<path>"
;;   node <address> <kind> <name> <startLine> <startOffset> <endOffset> <children>
;;   error <address> <kind> <line> "<what>" "<whatToDo>"
;;   end
;;
;; The first line is the shape's version. A reader that does not know the
;; number refuses the document and says which shape it wanted: an engine and an
;; editor that disagree refuse each other by version, by name
;; (contract/notation-engine-boundary.org). The last line is =end=; a document
;; without it is truncated, and this reader refuses it rather than answer half
;; a tree.
;;
;; Lines are 1-based and offsets are byte offsets into the file the =file= line
;; names (join/INDEX.org, "Bytes, not text, where it matters"). There is no
;; endLine field: model/nodes.rkt holds one line and one span per node and this
;; file does not invent a field the tree does not carry. The shape only grows:
;; a field added later is a new line shape, and a reader that meets one it does
;; not know refuses the document instead of skipping past the line
;; (contract/notation-engine-boundary.org, "How it changes").
;;
;; The loader half reads text and answers plain data. It requires nothing of
;; the model and nothing of the meaning side, so a consumer may take this file,
;; this contract and nothing else and still read a document. That is TODO
;; item 8's "loader works with the notation absent" — the editor keeps its own
;; features and this notation carries none of them (rule 14).

(require racket/list
         racket/string
         "../errors/raise.rkt")

(provide surface-header
         answers-node-fields
         answers-error-fields
         answers-document
         read-answers
         answers-at
         quoted-field
         split-fields
         unquoted-field
         (struct-out answer)
         (struct-out answer-error)
         (struct-out answers))


;; The version line. The number is the shape's version; a reader that does not
;; know it refuses the document rather than guess the shape.
(define surface-header "NOTATION-SURFACE 1")

;; The fields a node line carries, in order, and the fields an error line
;; carries. They are named here so a reader, a writer and a person reading
;; this file cannot disagree about the order, and read-answers counts every
;; line against them.
(define answers-node-fields
  '(address kind name start-line start-offset end-offset children))

;; answers-error-fields names the fields an error answer carries, so a
;; reader knows the shape of the answer it is given.
(define answers-error-fields
  '(address kind line what what-to-do))

;; One node as the editor sees it: where it is (address), what it is (kind,
;; name) and where its bytes are (the span). An answer carries no model node,
;; so nothing of the meaning side crosses the boundary in either direction.
(struct answer (address kind name start-line start-offset end-offset children)
  #:transparent)

;; One error the editor must show, named by the address of the text that
;; caused it. what-to-do is never empty: an error that cannot say what to do
;; is not an error yet.
(struct answer-error (address kind line what what-to-do) #:transparent)

;; A document that was read: the file it describes, the answers in it, and the
;; errors it carried, each list in document order.
(struct answers (file nodes errors) #:transparent)


;; answers-document prints one document back as the frozen text. The writer
;; and the reader are in this file because a shape written in one place and
;; read in another is a shape that drifts; both halves speak the fields above
;; and nothing else.
(define (answers-document a)
  (string-append
   (string-append surface-header "\n")
   (format "file ~a\n" (quoted-field (answers-file a)))
   (apply string-append (map answer-line (answers-nodes a)))
   (apply string-append (map answer-error-text (answers-errors a)))
   (string-append "end\n")))

;; answer-line prints one node line.
(define (answer-line n)
  (format "node ~a ~a ~a ~a ~a ~a ~a~%"
          (answer-address n)
          (answer-kind n)
          (answer-name n)
          (answer-start-line n)
          (answer-start-offset n)
          (answer-end-offset n)
          (answer-children n)))

;; answer-error-text prints one error line. It is not the accessor
;; answer-error-line that (struct-out answer-error) already brings in: that one
;; answers the line number, and a reader must never have to ask which of the two
;; a line of this file means.
(define (answer-error-text e)
  (format "error ~a ~a ~a ~a ~a~%"
          (answer-error-address e)
          (answer-error-kind e)
          (answer-error-line e)
          (quoted-field (answer-error-what e))
          (quoted-field (answer-error-what-to-do e))))


;; read-answers reads the frozen text back into a document. It refuses a
;; version it does not know, a line the shape does not define, a field count
;; that does not match, a number that is not a whole number, an error with
;; nothing to do about it, and a document with no =end= line. Every refusal
;; names what the reader may do next; none of them guesses.
(define (read-answers text)
  (define lines (string-split text "\n" #:trim? #f))
  (when (or (null? lines) (not (string=? (car lines) surface-header)))
    (raise-err 'answers "answers.rkt"
               (format "the document does not start with ~a, so this reader does not know its shape; ask the host for a surface document, compare the version lines first, and send it whole" surface-header)))
  (define file-path #f)
  (define nodes '())
  (define errors '())
  (define ended? #f)
  (let loop ([rest (cdr lines)])
    (cond
      [(null? rest) 'done]
      [ended? 'done]
      [else
       (define line (string-trim (car rest)))
       (cond
         [(string=? line "")
          (loop (cdr rest))]
         [(string=? line "end")
          (set! ended? #t)
          (loop (cdr rest))]
         [(string-prefix? line "file ")
          (set! file-path (unquoted-field (string-trim (substring line 5))))
          (loop (cdr rest))]
         [(string-prefix? line "node ")
          (set! nodes (cons (read-node-line line) nodes))
          (loop (cdr rest))]
         [(string-prefix? line "error ")
          (set! errors (cons (read-error-line line) errors))
          (loop (cdr rest))]
         [else
          (raise-err 'answers "answers.rkt"
                     (format "the document holds a line this shape does not define (~a); a reader must not skip a line it does not know — ask the host for a document of the shape ~a names" line surface-header))])]))
  (when (not ended?)
    (raise-err 'answers "answers.rkt"
               "the document has no end line, so it is truncated and the answers in it are not whole; read the whole file the host wrote, and ask for the answer again if it stops"))
  (define loaded (answers (or file-path "") (reverse nodes) (reverse errors)))
  (require-distinct-addresses loaded)
  loaded)

;; read-node-line reads
;; "node <address> <kind> <name> <startLine> <startOffset> <endOffset>
;;  <children>" and refuses a line that does not hold those fields.
(define (read-node-line line)
  (define parts (split-fields line))
  (unless (= (length parts) (+ 1 (length answers-node-fields)))
    (refuse-fields line parts answers-node-fields))
  (answer (list-ref parts 1)
          (list-ref parts 2)
          (list-ref parts 3)
          (field-number line (list-ref parts 4) "startLine")
          (field-number line (list-ref parts 5) "startOffset")
          (field-number line (list-ref parts 6) "endOffset")
          (field-number line (list-ref parts 7) "children")))

;; read-error-line reads
;; "error <address> <kind> <line> \"<what>\" \"<whatToDo>\"" and refuses an
;; error that arrives with nothing to say or nothing to do about.
(define (read-error-line line)
  (define parts (split-fields line))
  (unless (= (length parts) (+ 1 (length answers-error-fields)))
    (refuse-fields line parts answers-error-fields))
  (define what (unquoted-field (list-ref parts 4)))
  (define what-to-do (unquoted-field (list-ref parts 5)))
  (when (or (string=? what "") (string=? what-to-do ""))
    (raise-err 'answers "answers.rkt"
               (format "the error at ~a arrives with what ~a and what to do ~a; an error that cannot say what to do is not an error yet — send both, or leave the line out"
                       (list-ref parts 1) what what-to-do)))
  (answer-error (list-ref parts 1)
                (list-ref parts 2)
                (field-number line (list-ref parts 3) "line")
                what
                what-to-do))

;; refuse-fields says a line does not hold the fields the shape freezes, and
;; what to do about it. One wording for both kinds of line, so a reader's
;; answer to a drifting document is the same however it drifted.
(define (refuse-fields line parts fields)
  (raise-err 'answers "answers.rkt"
             (format "~a holds ~a fields where the shape names ~a; a field is missing or an extra one arrived — send a document of the shape ~a names"
                     line (length parts) fields surface-header)))

;; field-number reads a field that must hold a whole number. A field that is
;; not a number is a broken shape, not a zero: 0 means "not known" and is only
;; ever written on purpose.
(define (field-number line field what)
  (define n (string->number field))
  (unless (and n (exact-integer? n))
    (raise-err 'answers "answers.rkt"
               (format "~a is ~a in ~a where the shape says a whole number — write the field as a number, and send a document of the shape ~a names"
                       what field line surface-header)))
  n)

;; require-distinct-addresses refuses a document where two answers claim one
;; address. An address that names two nodes names nothing, and the editor
;; stores exactly this string, so the check happens where the text is read and
;; not only where it is written.
(define (require-distinct-addresses a)
  (define seen (make-hash))
  (for-each
   (lambda (n)
     (when (hash-has-key? seen (answer-address n))
       (raise-err 'answers "answers.rkt"
                  (format "two answers claim the address ~a, so that address names nothing; an editor would store the wrong node — ask the host which document answered, and send it again"
                          (answer-address n))))
     (hash-set! seen (answer-address n) #t))
   (answers-nodes a)))


;; answers-at answers the node one address names, or #f when the document
;; holds no such node. A miss is an answer and not a refusal: the editor asks
;; for an address it stored a moment ago and must not crash because the node
;; it named has moved or gone.
(define (answers-at a address)
  (findf (lambda (n) (string=? (answer-address n) address)) (answers-nodes a)))


;; Quoting is the rule frozen in join/INDEX.org: a quoted field is wrapped in
;; double quotes, the spaces inside are kept as written, a double quote inside
;; is written twice, and no newline ever appears inside. It is written here
;; once for this whole area — answers.rkt and notices.rkt both quote this way,
;; and one home for a vocabulary beats two — and it is written rather than
;; borrowed from model/outline.rkt, because this file must require nothing of
;; the model to read a document.

;; quoted-field writes one field in that form.
(define (quoted-field text)
  (format "\"~a\"" (string-replace (format "~a" text) "\"" "\"\"")))

;; split-fields reads a line into its fields and keeps a quoted field whole:
;; the spaces inside it belong to the field. This is why the loader does not
;; simply split on spaces.
(define (split-fields line)
  (let loop ([cs (string->list line)] [cur '()] [quoted? #f] [out '()] [fresh? #t])
    (cond
      [(null? cs)
       (when quoted?
         (raise-err 'answers "answers.rkt"
                    (format "a quoted field in ~a is never closed; send the whole line again, with both quotes around the quoted field" line)))
       (reverse (if (null? cur) out (cons (list->string (reverse cur)) out)))]
      [fresh?
       (cond
         [(char=? (car cs) #\space) (loop (cdr cs) '() quoted? out #t)]
         [(char=? (car cs) #\") (loop (cdr cs) '() #t out #f)]
         [else (loop cs '() quoted? out #f)])]
      [quoted?
       (cond
         [(char=? (car cs) #\")
          (if (and (pair? (cdr cs)) (char=? (cadr cs) #\"))
              (loop (cddr cs) (cons #\" cur) #t out #f)
              (loop (cdr cs) '() #f out #t))]
         [else (loop (cdr cs) (cons (car cs) cur) #t out #f)])]
      [else
       (if (char=? (car cs) #\space)
           (loop (cdr cs) '() #f out #t)
           (loop (cdr cs) (cons (car cs) cur) #f out #f))])))

;; unquoted-field gives the text a reader wants: the quotes come off and a
;; doubled quote inside becomes one quote.
(define (unquoted-field field)
  (if (and (> (string-length field) 1)
           (char=? (string-ref field 0) #\")
           (char=? (string-ref field (- (string-length field) 1)) #\"))
      (string-replace (substring field 1 (- (string-length field) 1)) "\"\"" "\"")
      field))
