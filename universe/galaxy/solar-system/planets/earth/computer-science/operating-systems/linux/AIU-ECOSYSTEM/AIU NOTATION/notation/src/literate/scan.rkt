#lang racket/base
;; One job: dependency scanning over the chunks — what waits on what, and what
;; a reader must be told about.
;; Registered in plan/package-tree.org (literate/scan.rkt). Lands with TODO
;; item 6 (build step 5, literate code).
;;
;; Scanning reads names and depends: lines and runs nothing. That is the whole
;; discipline (engine/code-chunk-graph.org: the graph is scanned without
;; executing anything), and it is why a chunk that would need a language to run
;; is still safe to list here.
;;
;; Scanning answers two questions. The first is what is wrong with the graph:
;; a name two chunks share, a chunk that waits on itself, a dependency nothing
;; carries, a loop nobody can send in, a target this run may not write. Each
;; answer is a finding — data, never a printed line — and each one is said out
;; loud as it is found, because a finding that is only stored is a finding the
;; reader never meets.
;;
;; The second answer is the send order: a chunk is sent after every chunk it
;; depends on, so a chunk is never sent before the text it was written against.
;; That order is computed here and nowhere else; a loop has no order, so a
;; graph with a loop in it is refused the order instead of being given one
;; that happens to work today.
;;
;; Narration: one step line and one warn per finding. There is no wait: the
;; graph is in memory, so nothing in this file can block.

(require racket/list
         racket/string
         "chunks.rkt"
         "targets.rkt"
         "../errors/raise.rkt"
         "../narration/narration.rkt")

(provide scan-chunks chunk-send-order (struct-out scan-finding))


;; One thing a reader must know about the graph. who is the document it is
;; about, line is the 1-based line where the thing sits, what is wrong in one
;; sentence, and what-to-do is never empty — the shape diagnostics/collect.rkt
;; already uses, because a reader can act on it. This struct is not that
;; struct: adding a kind of finding to diagnostics/ is a change in that area,
;; and this one is reported rather than made from here.
(struct scan-finding (who line what what-to-do) #:transparent)


;; scan-chunks reads the whole graph and returns every finding, in the order
;; they were looked for. The order is fixed so two runs over one document give
;; the same list, and each group is said out loud as it is found: a later group
;; that refuses must not take the earlier findings down with it.
(define (scan-chunks graph)
  (define who (or (chunk-graph-file graph) "a document with no file name"))
  (say-step "scanning the chunks"
            (format "~a chunk(s) and ~a declared edge(s) in ~a, read without running anything"
                    (length (chunk-graph-chunks graph))
                    (length (chunk-graph-edges graph))
                    who))
  (define found '())
  (define (note! more)
    (for-each (lambda (f) (say-warn (scan-finding-what f) (scan-finding-what-to-do f)))
              more)
    (set! found (append found more)))
  (note! (shared-name-findings graph who))
  (note! (self-findings graph who))
  (note! (unknown-findings graph who))
  (note! (loop-findings graph who))
  (note! (place-findings graph who))
  found)

;; shared-name-findings: two chunks with one name. A send names a chunk by name
;; and by nothing else, so a repeated name leaves the run unable to say which
;; chunk it means.
(define (shared-name-findings graph who)
  (for/list ([n (repeated-names (chunk-graph-chunks graph))])
    (scan-finding who (line-of graph n)
                  (format "two chunks are both named ~a" n)
                  "give each chunk its own name; a send names a chunk by name alone")))

;; repeated-names lists a name more than once, each name once.
(define (repeated-names chunks)
  (define names (map chunk-name chunks))
  (remove-duplicates (filter (lambda (n) (> (count-of n names) 1)) names)))

;; self-findings: a chunk that declares itself as a dependency.
(define (self-findings graph who)
  (for/list ([n (chunk-names graph)]
             #:when (member n (chunk-dependencies graph n)))
    (scan-finding who (line-of graph n)
                  (format "the chunk ~a depends on itself" n)
                  "drop its own name from the depends: line; a chunk cannot wait on itself")))

;; unknown-findings: a dependency no chunk carries. It is kept in the graph on
;; purpose (chunks.rkt), so that the report is here and not silently gone.
(define (unknown-findings graph who)
  (for/list ([pair (unknown-dependencies graph)])
    (scan-finding who (line-of graph (car pair))
                  (format "the chunk ~a depends on ~a, and no chunk in this document carries that name"
                          (car pair) (cdr pair))
                  (format "write ~a as a chunk: name in the document, or drop it from the depends: line of ~a"
                          (cdr pair) (car pair)))))

;; unknown-dependencies lists the (chunk . name) pairs that name nothing.
(define (unknown-dependencies graph)
  (append-map (lambda (c)
                (map (lambda (d) (cons (chunk-name c) d))
                     (filter (lambda (d) (not (chunk-for graph d))) (chunk-depends c))))
              (chunk-graph-chunks graph)))

;; loop-findings: chunks that wait on each other, and the chunks that queue up
;; behind them. The two are named apart: one is a loop the reader must break,
;; the other is only waiting for the loop to be broken.
(define (loop-findings graph who)
  (define waiting (waiting-chunks graph))
  (define looping (filter (lambda (n) (waits-on-waiting? graph n waiting)) waiting))
  (cond
    [(null? looping) '()]
    [else
     (define queue (filter (lambda (n) (not (member n looping))) waiting))
     (list (scan-finding
            who (line-of graph (car looping))
            (format "the chunks ~a wait on each other; no order sends them"
                    (looping-names looping))
            (if (null? queue)
                "remove one of the depends: lines so that each chunk waits only on chunks before it"
                (format "remove one of the depends: lines among them; ~a wait on them and cannot be sent first either"
                        (looping-names queue)))))]))

;; waits-on-waiting? says a name depends on another name that also cannot go.
(define (waits-on-waiting? graph name waiting)
  (for/or ([d (chunk-dependencies graph name)])
    (member d waiting)))

;; looping-names writes a list of names as one phrase, so a message reads
;; "a, b and c" instead of "(a b c)".
(define (looping-names names)
  (string-join names ", "))

;; place-findings: a target this run may not write into. It is a finding and
;; not a refusal, so one chunk with such a target does not stop the others
;; from being planned; the run loads that chunk in place and says so.
(define (place-findings graph who)
  (for/list ([c (chunk-graph-chunks graph)]
             #:when (place-not-writable? graph c))
    (scan-finding who (chunk-line c)
                  (format "the chunk ~a names ~a, which this run does not write into"
                          (chunk-name c) (place-as-written (chunk-into c)))
                  "name the whole file after into: to have it sent; a place inside a file notation did not write is not spliced yet")))

;; place-not-writable? asks targets.rkt, which owns what a target may be.
(define (place-not-writable? graph c)
  (define t (target-of-chunk c))
  (and t (not (whole-file-target? t))))

;; place-as-written is the place without the path, for a finding about the
;; place alone.
(define (place-as-written written)
  (define parts (string-split written " at " #:trim? #f #:repeat? #f))
  (if (null? (cdr parts)) "the whole file" (cadr parts)))

;; chunk-send-order lists the chunk names in the order they may be sent: a
;; chunk comes after every chunk it depends on. A graph with a loop in it has
;; no such order, so this raises rather than returning one that only happens to
;; work today. scan-chunks says the same thing as a finding first.
(define (chunk-send-order graph)
  (define-values (placed waiting) (placed-chunks graph))
  (when (pair? waiting)
    (raise-err 'scan "scan.rkt"
               (format "the chunks ~a wait on each other, so there is no order to send them in; scan-chunks names them"
                       (looping-names waiting))))
  placed)

;; waiting-chunks lists the chunks that cannot be sent yet: after every chunk
;; that can go has gone, they are the ones left, and they are the loop.
(define (waiting-chunks graph)
  (define-values (placed waiting) (placed-chunks graph))
  (filter (lambda (n) (not (member n placed))) waiting))

;; placed-chunks returns the names in the order they may be sent — a chunk
;; after every chunk it depends on, never before — and the names still waiting
;; when a whole round moves nothing. It is a fixpoint: each round places every
;; chunk whose dependencies have already gone. There is no recursion here, so a
;; long chain of chunks cannot cost a stack.
(define (placed-chunks graph)
  (let loop ([placed '()] [left (chunk-names graph)])
    (define moved (filter (lambda (n) (ready-now? graph placed n)) left))
    (cond
      [(null? moved) (values placed left)]
      [else
       (loop (append placed moved)
             (filter (lambda (n) (not (member n moved))) left))])))

;; ready-now? says every chunk this one depends on has already gone. A
;; dependency no chunk carries cannot be waited for: unknown-findings reports
;; it, and holding the whole graph for it would say the same thing twice.
(define (ready-now? graph placed name)
  (for/and ([d (chunk-dependencies graph name)])
    (or (not (chunk-for graph d))
        (member d placed))))

;; line-of is the line a chunk's block opens on, so a finding points at the
;; place in the document rather than at the chunk in general.
(define (line-of graph name)
  (define c (chunk-for graph name))
  (if c (chunk-line c) 0))
