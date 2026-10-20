#lang racket/base
;; One job: accept and undo — the human's answer to a change, and the
;; undo that is safe. Registered in plan/package-tree.org; lands with
;; TODO item 11.
;;
;; Accepting a change says: this one is wanted. It is recorded, and the
;; record is in the audit log beside the mark, so the history reads in
;; one place.
;;
;; Undoing a change puts the file back to the state the checkpoint had.
;; The undo NEVER GUESSES: when the file changed again since the mark
;; was made, the undo is refused by name, because the change the human
;; meant to undo is not the change that is there now. That refusal is
;; the conflict test, and it is the whole point of the mark's second
;; hash.
;;
;; A file that the checkpoint did not have is not deleted: it is kept
;; in the state directory first, so the bytes are never lost (rule 01).
;;
;; Registered in plan/package-tree.org; lands with TODO item 11.

(require racket/file
         racket/list
         racket/path
         racket/string
         "../checkpoint/checkpoint.rkt"
         "../machine/directories.rkt"
         "../narration/events.rkt"
         "../security/security.rkt"
         "audit.rkt")

;; kept-dir is where the files an undo took away are kept: the bytes
;; are never lost, so a mistake can be taken back.
(define kept-dir
  (build-path (state-dir) "audit" "kept"))

;; accept-mark records that the human wanted this change, and answers
;; the mark with the acceptance in it.
(define (accept-mark mark)
  (write-mark (hash-set mark 'accepted (utc-now))))

;; undo-mark puts the file back to the state the checkpoint had, and
;; answers what it did. It refuses by name when the file changed again
;; since the mark: the change the human meant is not the change that is
;; there now.
(define (undo-mark root mark)
  (define path-text (hash-ref mark 'path ""))
  (define path (path->complete-path path-text))
  (define checkpoint (hash-ref mark 'checkpoint ""))
  (cond
    [(string=? path-text "")
     (list #f "a mark without a path cannot be undone")]
    [(not (state-changing? "undo"))
     (list #f "the undo is not a change of the tree, and it is refused")]
    [(not (reversible? "undo"))
     (list #f "the undo cannot be taken back, and it is refused")]
    [(not (file-exists? path))
     (list #f (format "there is nothing to undo: ~a is not there" path))]
    [(not (string=? (file-hash path) (hash-ref mark 'hash-after "")))
     (list #f (format "the undo was refused: ~a changed again since the mark, so it is not the change that was marked" path))]
    [else
     (if (string=? (hash-ref mark 'hash-before "") "")
         (undo-new-file root path)
         (undo-known-file root path checkpoint))]))

;; undo-known-file puts a file back to the state the checkpoint had.
(define (undo-known-file root path checkpoint)
  ;; git says nothing when it puts a file back, so the STATUS is what
  ;; says whether it worked
  (if (git-ok? root "checkout" checkpoint "--" (path-relative path))
      (list (format "the file is back at the checkpoint: ~a" path) #f)
      (list #f (format "the file could not be put back: ~a" path))))

;; undo-new-file takes a file the checkpoint did not have away from the
;; tree, and keeps it: the bytes go to the state directory first, so
;; nothing is lost (rule 01).
(define (undo-new-file root path)
  (ensure-dir kept-dir)
  (define kept (build-path kept-dir (file-name-from-path path)))
  (copy-file path kept)
  (delete-file path)
  (list (format "the file was taken away and kept: ~a" kept) #f))

;; The accept and the undo, for the area above them.
(provide kept-dir
         accept-mark
         undo-mark)
