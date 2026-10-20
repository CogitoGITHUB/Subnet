#lang racket/base
;; One job: the live audit — what changed in the tree, and who changed
;; it. Registered in plan/package-tree.org; lands with TODO item 11.
;;
;; A change the agent reported is marked AGENT. A change nobody
;; reported is marked EXTERNAL: the editor does not guess who touched
;; the tree, and it never claims the agent did something the agent did
;; not say (contract/event-log-format.org).
;;
;; The marks are written as the change lands, on the event that caused
;; it, and they are flushed per record: a killed process leaves a
;; readable prefix, never a torn record (rule 01, rule 04). There is no
;; timer anywhere: the audit runs when something happened, not on a
;; clock (rule 03).
;;
;; The audit lives in the AUDIT area, above the send area and the
;; checkpoint area, because it asks both of them.
;;
;; Registered in plan/package-tree.org; lands with TODO item 11.

(require json
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         "../checkpoint/checkpoint.rkt"
         "../machine/directories.rkt"
         "../narration/events.rkt"
         "../send/opencode-adapter.rkt")

;; audit-dir is where the audit keeps its records: the marks and the
;; copies of the files it undid. They live in the state directory,
;; because they must survive a crash.
(define audit-dir
  (build-path (state-dir) "audit"))

;; audit-log is the log of the marks: one record per line, in the JSON
;; shape the contract names.
(define audit-log
  (build-path audit-dir "marks.jsonl"))

;; make-mark answers a mark: the path that changed, who changed it,
;; the session it came from, the checkpoint it is judged against, and
;; the two hashes — the one before the change and the one after it.
(define (make-mark path who session-id checkpoint)
  (hash 'path (path->string path)
        'who who
        'session session-id
        'checkpoint checkpoint
        'utc (utc-now)
        'hash-before (file-hash-at checkpoint path)
        'hash-after (file-hash path)))

;; write-mark writes one mark to the log and flushes it: a killed
;; process leaves a readable prefix, never a torn record.
(define (write-mark mark)
  (ensure-dir audit-dir)
  (call-with-output-file audit-log
    (lambda (port)
      ;; write-json writes the mark and answers nothing: the text of the
      ;; void is NOT written after it, so every line is one mark and the
      ;; log reads back one mark per line
      (write-json mark port)
      (newline port))
    #:exists 'append)
  mark)

;; audit-marks answers the marks in the log, oldest first. A log that is
;; not there yet means no mark was made yet, and the answer is empty.
(define (audit-marks)
  (if (file-exists? audit-log)
      (filter values
              (for/list ([line (in-list (read-lines audit-log))])
                (with-handlers ([exn:fail? (lambda (why) #f)])
                  (read-json (open-input-string line)))))
      '()))

;; read-lines answers the lines of a file, one per line.
(define (read-lines path)
  (call-with-input-file path
    (lambda (port)
      (let loop ([out '()])
        (define line (read-line port))
        (if (eof-object? line)
            (reverse out)
            (loop (cons line out)))))))

;; observe-changes looks at the tree, compares it with the checkpoint,
;; and answers the marks of what changed: one mark per changed file, the
;; agent's changes marked AGENT and everything else EXTERNAL.
(define (observe-changes root checkpoint client session-id)
  (define reported (agent-reported-files client session-id))
  (for/list ([path (in-list (changed-files root checkpoint))])
    (write-mark
     (make-mark (build-path root path)
                (if (member path reported) "agent" "external")
                session-id
                checkpoint))))

;; agent-reported-files answers the files the agent said it touched: the
;; files of the permission asks that are still open, and the files the
;; asks named. A file nobody reported is nobody's to claim.
(define (agent-reported-files client session-id)
  (if (not session-id)
      '()
      (remove-duplicates
       (append* (for/list ([ask (in-list (client-permissions client session-id))])
                  (ask-files ask))))))

;; changed-files answers the files that differ from the checkpoint: the
;; tracked files that changed, and the files that are new and not
;; tracked. A file that is not there any more is gone, and the audit
;; says so by name.
(define (changed-files root checkpoint)
  (if (or (string=? checkpoint "") (not (git-ok? root "cat-file" "-e" checkpoint)))
      '()
      (append (changed-tracked root checkpoint)
              (untracked-files root))))

;; changed-tracked answers the tracked files that differ from the
;; checkpoint.
(define (changed-tracked root checkpoint)
  (filter (lambda (line) (not (string=? line "")))
          (string-split (run-git root "diff" "--name-only" checkpoint) "\n")))

;; file-hash answers the content hash of a file as it is now, or the
;; empty text when the file is not there.
(define (file-hash path)
  (if (file-exists? path)
      (string-trim (run-git (tree-root path) "hash-object" path))
      ""))

;; file-hash-at answers the content hash of a file as the checkpoint
;; had it, or the empty text when the file was not there yet: a new
;; file has no "before".
(define (file-hash-at checkpoint path)
  (if (or (string=? checkpoint "") (not (file-exists? path)))
      ""
      (string-trim (run-git (tree-root path) "rev-parse"
                             (string-append checkpoint ":" (path-relative path))))))

;; path-relative answers the name git knows a path by: the path inside
;; its tree, without the tree's own name in front of it. Git asks for
;; the name inside the tree, and the human gives the whole path.
(define (path-relative path)
  (define root (simplify-path (tree-root path)))
  (define root-text (string-append (path->string root) "/"))
  (define full (path->string (simplify-path (path->complete-path path))))
  (if (starts-with? full root-text)
      (substring full (string-length root-text))
      full))

;; starts-with? answers whether a text begins with another text.
(define (starts-with? text prefix)
  (and (>= (string-length text) (string-length prefix))
       (string=? (substring text 0 (string-length prefix)) prefix)))

;; The audit, for the area above it.
(provide path-relative
         audit-dir
         audit-log
         make-mark
         write-mark
         audit-marks
         observe-changes
         agent-reported-files
         changed-files
         file-hash
         file-hash-at)
