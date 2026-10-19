#lang racket/base
;; One job: what would be written — the dry-run shape, built and said, and not
;; written.
;; Registered in plan/package-tree.org (generation/plan.rkt). Lands with TODO
;; item 6 (build step 5, literate code).
;;
;; A plan is the whole act before any of it happens: one step per chunk, in the
;; order the chunks may be sent, each carrying the text that would go to disk,
;; the content hash that text is named by, and the decision the store already
;; made about it. Building it touches no file, so the same plan answers the
;; question "what would this run do?" and the question "what did this run do?".
;;
;; Two things are decided here and nowhere else:
;;   - the content hash of a chunk, which is the hash of its source, of every
;;     chunk hash it depends on, and of where it goes. A chunk that depends on
;;     another therefore changes when that other changes, which is what makes
;;     an unchanged hash worth trusting.
;;   - whether a chunk is sent or loaded. A chunk that names no target is
;;     loaded in place and written nowhere; a chunk whose target is a place
;;     inside a file notation did not write is loaded in place today and
;;     reported by scan.rkt, because splicing into a file somebody else owns is
;;     the owner's open decision and not this file's.
;;
;; The skip sentence is NOT written here: a send step carries the decision that
;; decide-skip already spoke, so a skip is said once, in one place, whether the
;; run goes on to write or stops at the plan.
;;
;; Narration: the order is announced as a decision, each load is named, and
;; the plan is counted. Every send step speaks through the decision it carries,
;; which skip-journal.rkt already said. There is no wait in this file: it
;; builds a shape and writes nothing, so nothing in it can block.

(require racket/list
         racket/string
         "../literate/chunks.rkt"
         "../literate/scan.rkt"
         "../literate/skip-journal.rkt"
         "../literate/targets.rkt"
         "../narration/narration.rkt"
         "../narration/print-console.rkt")

(provide build-plan print-plan plan-step-reason (struct-out plan-step))


;; One planned act: to send a chunk into a target, or to load a chunk in place.
;; hash is the content hash the step is named by; text is the exact string
;; that would go to disk, and it is #f for a load because nothing is written;
;; decision is what the store said, and it is #f for a load because nothing was
;; ever going to be written for it.
(struct plan-step (action chunk-name target-path hash text decision) #:transparent)


;; build-plan reads the graph and answers the whole run, without writing.
(define (build-plan graph store)
  (define order (chunk-send-order graph))
  (when (pair? order)
    (say-decide (format "the order to send in: ~a" (names-as-one-phrase order))
                "each chunk is sent after every chunk it depends on, so no chunk is sent against text that has not been sent yet"))
  (define steps (plan-steps-in-order graph store order '()))
  (say-step "the plan"
            (format "~a chunk(s) in ~a: ~a to send and ~a to load in place; nothing is written until the plan is carried out"
                    (length (chunk-graph-chunks graph))
                    (or (chunk-graph-file graph) "a document with no file name")
                    (plan-sends steps)
                    (plan-loads steps)))
  steps)

;; plan-steps-in-order walks the send order and builds each step. hashes is the
;; (name . hash) pairs placed so far, which is how a chunk's material reaches
;; the chunks it depends on: they are placed first, so their hashes are known
;; by the time they are needed. A dependency no chunk carries is material in
;; its own right — its name goes into the hash — so a document that fixes the
;; missing chunk changes this chunk's hash and this chunk is sent again.
(define (plan-steps-in-order graph store order hashes)
  (cond
    [(null? order) '()]
    [else
     (define name (car order))
     (define c (chunk-for graph name))
     (define target (target-of-chunk c))
     (define sends (and target (whole-file-target? target)))
     (define hash
       (hash-together (list (chunk-source c)
                            (if target (target-place-word target) "loads in place")
                            (if target (target-path target) "")
                            (dependency-material hashes (chunk-depends c)))))
     (define step
       (if sends
           (plan-step 'send name (target-path target) hash (written-text (chunk-source c))
                      (decide-skip store name (target-path target) hash))
           (plan-step 'load name (if target (target-path target) "") hash #f #f)))
     (unless sends
       (say-step (format "loading the chunk ~a" name) (load-reason target)))
     (cons step (plan-steps-in-order graph store (cdr order) (cons (cons name hash) hashes)))]))

;; dependency-material is what a chunk's dependencies contribute to its hash:
;; each dependency's hash when it has one, and its name when nothing carries
;; it. The two are joined so that neither can be mistaken for the other.
(define (dependency-material hashes deps)
  (string-join
   (map (lambda (d)
          (define entry (assq d hashes))
          (if entry (cdr entry) (format "no chunk named ~a" d)))
        deps)
   " "))

;; written-text is the exact string a target file would hold. The source is the
;; body lines joined without a final newline, because the newline that ends the
;; last line belongs to the file; adding it back is what makes a generated file
;; end with exactly one newline.
(define (written-text source)
  (string-append source "\n"))

;; load-reason says why a chunk is not written anywhere, in words a reader can
;; act on. The two reasons are different things: one is a decision the author
;; wrote, the other is a gap this program has not closed yet.
(define (load-reason target)
  (cond
    [(not target)
     "it names no into: line, so it loads in place and is written nowhere"]
    [else
     (format "its target names ~a, which this run does not write into; the source stays in the document and the target is left as it is"
             (target-label target))]))

;; plan-sends and plan-loads count the steps of each act.
(define (plan-sends steps)
  (count (lambda (a) (eq? a 'send)) (map plan-step-action steps)))

(define (plan-loads steps)
  (count (lambda (a) (eq? a 'load)) (map plan-step-action steps)))

;; plan-step-line is one step as one line, for a dry run: what would happen, to
;; which file, under which hash, and what the store said. A skip shows the
;; sentence decide-skip spoke, so a dry run carries the same words a real run
;; does.
(define (plan-step-line s)
  (define name (plan-step-chunk-name s))
  (define hash (plan-step-hash s))
  (cond
    [(eq? (plan-step-action s) 'load)
     (format "load  ~a  hash ~a  in place; nothing is written for it" name hash)]
    [else
     (format "send  ~a  →  ~a  hash ~a  ~a"
             name
             (plan-step-target-path s)
             hash
             (plan-step-reason s))]))

;; plan-step-reason is the reason a send step carries, and for a skip it is the
;; sentence that names the hash that matched.
(define (plan-step-reason s)
  (skip-decision-reason (plan-step-decision s)))

;; print-plan prints the plan through the one printer in the package, one line
;; per step and one line of count. It is the dry run: it writes nothing.
(define (print-plan steps)
  (for-each print-line (map plan-step-line steps))
  (print-line (format "~a plan step(s): ~a to send, ~a to load in place"
                       (length steps) (plan-sends steps) (plan-loads steps))))

;; names-as-one-phrase writes a list of names as one phrase, so a message reads
;; "a, b and c" instead of "(a b c)".
(define (names-as-one-phrase names)
  (string-join names ", "))
