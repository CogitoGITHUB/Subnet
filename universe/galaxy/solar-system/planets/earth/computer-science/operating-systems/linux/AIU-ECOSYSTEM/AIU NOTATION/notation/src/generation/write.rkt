#lang racket/base
;; One job: write through security, into declared targets only.
;; Registered in plan/package-tree.org (generation/write.rkt). Lands with TODO
;; item 6 (build step 5, literate code).
;;
;; This is the only place in the package that writes a document's content, and
;; it writes one thing: the text of a planned send, into the target the
;; document declared. Four things are refused before a byte moves, and each
;; refusal names what the reader may do:
;;   - a target that is not a declared one: targets.rkt's door already refused
;;     an absolute path, a directory and a path that climbs out with "..".
;;   - a target that is the document itself, which would cost the source
;;     (rules/rule-01-never-lose-work.org).
;;   - a target file that exists and that this document's store holds nothing
;;     sent to it, so no run of this document ever wrote it. Replacing a file
;;     nobody sent is how work is lost, and the way out is a human's: delete it
;;     yourself, or point the target at a file of its own.
;;   - a step that is a load. A load is written nowhere by definition.
;;
;; The security area (security/security.rkt, output-safe? and state-changing?)
;; does not exist yet and is named in plan/package-tree.org. These four
;; refusals are this file's own door while that is true; when the area lands
;; they are replaced by its answers, not added to. gate/security-gate-lint.nu
;; says NOTHING-TO-CHECK for exactly this reason.
;;
;; A write is never a half-written file: the text goes to a .new file beside
;; the target and is renamed over it in one step. A crash costs the new file
;; and never the old one, and the rename leaves nothing behind.
;;
;; Narration and waits: the writer lock, the write itself and the store entry
;; are all blocks on a disk that may be slow, full or gone, so each says what
;; it is about to do and why before it blocks and again when it is through.
;; The refusal reasons and the per-step reason come from the decision the plan
;; already holds, so a send is never explained twice in two wordings.

(require racket/file
         racket/list
         racket/path
         "../errors/raise.rkt"
         "../literate/skip-journal.rkt"
         "../machine/directories.rkt"
         "../machine/locks.rkt"
         "../narration/narration.rkt"
         "../narration/wait-door.rkt"
         "plan.rkt")

(provide send-plans send-wrote? (struct-out send-result))


;; What one send step did: the chunk, the file it went to, and what happened.
;; 'written means the file now holds the text; 'skipped means the store matched
;; the content hash and the file was left alone; 'not-sent means the step was
;; a load, which is written nowhere.
(struct send-result (chunk-name target-path outcome) #:transparent)

;; send-wrote? answers whether a result means a file was written.
(define (send-wrote? r)
  (eq? (send-result-outcome r) 'written))


;; send-plans carries out a plan and answers what happened, one result per step.
;; It also forgets the store entries no planned chunk needs any more, so the
;; store stays the size of the document instead of growing with every run.
(define (send-plans document-path steps store)
  (with-wait "opening the writer lock directory"
             "so two runs cannot write one target at once; the locks live in the run's state directory, not beside a document"
    (ensure-dir (lock-directory)))
  (define results (map (lambda (s) (send-plan document-path s store)) steps))
  (forget-sent store (map plan-step-hash (filter send-step? steps)))
  (say-note "the run"
            (format "~a file(s) written, ~a skipped as unchanged, ~a loaded in place"
                    (count send-wrote? results)
                    (count send-skipped? results)
                    (count send-loaded? results)))
  results)

;; send-plan carries out one step. A load is answered and not written. A step
;; the store already matched is answered as skipped and not written either: the
;; plan made that decision by comparing the content hash, and this file does
;; not second-guess it by writing anyway. A send that was not skipped takes the
;; writer lock for its target, says why it is writing, and leaves the store
;; standing for what it wrote.
(define (send-plan document-path step store)
  (cond
    [(not (send-step? step))
     (send-result (plan-step-chunk-name step) (plan-step-target-path step) 'not-sent)]
    [(not (decision-sends? (plan-step-decision step)))
     (send-result (plan-step-chunk-name step) (plan-step-target-path step) 'skipped)]
    [else
     (define target (target-path-of document-path (plan-step-target-path step)))
     (require-replaceable target document-path store)
     (with-lock (lock-path target)
                (lambda ()
                  (say-step (format "sending the chunk ~a → ~a"
                                    (plan-step-chunk-name step) target)
                            (plan-step-reason step))
                  (write-file-at target (plan-step-text step))
                  (record-send store target (plan-step-hash step) (plan-step-text step))
                  (send-result (plan-step-chunk-name step) target 'written)))]))

;; send-step? says a step writes something. The plan already decided this; a
;; load is not refused here, it is answered.
(define (send-step? step)
  (eq? (plan-step-action step) 'send))

(define (send-skipped? r)
  (eq? (send-result-outcome r) 'skipped))

(define (send-loaded? r)
  (eq? (send-result-outcome r) 'not-sent))


;; require-replaceable is the door in front of every write. It refuses the two
;; cases where writing would cost something: the document itself, and a file
;; this document's store holds nothing sent to.
(define (require-replaceable target document-path store)
  (cond
    [(same-file? target document-path)
     (raise-err 'write "write.rkt"
                (format "~a is the document itself; writing it would cost the source, so no into: line may name the document" target))]
    [(not (file-exists? target)) (void)]
    [(store-owns-target? store target) (void)]
    [else
     (raise-err 'write "write.rkt"
                (format "~a exists and nothing this document sent is recorded for it; delete it yourself, or point the into: line at a file of its own"
                        target))]))

;; same-file? compares the two paths as they are written, once simplified. It
;; is not a device-inode test and does not pretend to be: it catches the target
;; that names the document, which is the case that costs the source.
(define (same-file? target document-path)
  (equal? (simplify-path target) (simplify-path document-path)))

;; target-path-of resolves a declared target against the document's own
;; directory. targets.rkt already refused anything that may not be written, so
;; this only joins the two paths and simplifies them: one target spelled two
;; ways is one file and must take one lock.
(define (target-path-of document-path written)
  (define here (if (path-only document-path) (path-only document-path) "."))
  (path->string (simplify-path (build-path here written))))

;; lock-path is where the one-writer lock for a target lives: in the run's
;; state directory, named by the hash of the path. A lock file is a file this
;; run writes and the document never declared, so it stays out of the
;; document's own directory.
(define (lock-path target)
  (build-path (lock-directory) (text-hash target)))

(define (lock-directory)
  (build-path (notation-state-dir) "generation-locks"))


;; write-file-at puts text in a file without ever leaving a half-written one:
;; the text goes to a .new file beside the target and is renamed over it in one
;; step. The .new file is the only other path this run writes, it sits beside a
;; declared target, and the rename leaves nothing behind.
;;
;; The directory a target implies is created if it is missing, because a target
;; that names plan/x.org means that directory is part of what was declared.
(define (write-file-at target text)
  (define beside (beside-target target))
  (ensure-dir (if (path-only target) (path-only target) "."))
  (with-wait (format "writing ~a" target)
             "the text goes to a .new file beside it and is renamed over it in one step, so a crash costs the new file, never the old one"
    (call-with-output-file beside #:exists 'truncate (lambda (out) (display text out)))
    (rename-file-or-directory beside target #t)))

(define (beside-target target)
  (build-path (if (path-only target) (path-only target) ".")
              (string-append (path->string (file-name-from-path target)) ".new")))
