#lang racket/base
;; One job: the rollback — the tree goes back to a checkpoint. Registered
;; in plan/package-tree.org; lands with TODO item 12.
;;
;; The rollback is the checkpoint's other half: the commit it made is the
;; state the tree is put back to. The rollback never guesses: a commit
;; that is not there is refused by name, and a tree with work that was
;; never committed is named before anything is thrown away.
;;
;; Registered in plan/package-tree.org; lands with TODO item 12.

(require racket/list
         racket/string
         "checkpoint.rkt")

;; rollback puts the tree back to a checkpoint and answers what it did.
;; The commit is the one the checkpoint named.
(define (rollback root commit)
  (cond
    [(string=? (string-trim commit) "")
     (list #f "a rollback needs the name of a checkpoint")]
    [(not (git-ok? root "cat-file" "-e" commit))
     (list #f (format "there is no checkpoint named ~a" commit))]
    [else
     (define moved (run-git root "reset" "--hard" commit))
     (if (string=? moved "")
         (list #f (format "the tree could not go back to ~a" commit))
         (list (string-trim commit) #f))]))

;; The rollback, for the entry above it.
(provide rollback)
