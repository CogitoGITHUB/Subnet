#lang racket/base
;; link-target.rkt -- the TARGET TEXT of a symbolic link: what the link
;; points at, as text, without following it.
;;
;; It lives in git/ for two reasons. A link's target is what git records
;; for a link, so the shape belongs here; and the area law (D-044) says
;; git/ may reach process/ and store/ may reach git/, so the one spawn
;; this needs sits BELOW the store that asks for it. The store must stay
;; pure: it hashes a tree, and it never starts a process to do it.
;;
;; WHY A SPAWN: this Racket exports no read-symlink, and the two
;; alternatives are both wrong. resolve-path follows the link, so a
;; dangling link cannot be read at all; and opening the link as a file
;; hashes the link as if it were a regular file, which is not what the
;; link IS. The link's target is its own text, and readlink is the one
;; tool that answers it.
;;
;; The read is never silent: a link that cannot be read is a refusal
;; with its path and its reason, not an empty target.

(require racket/path
         racket/string
         "../errors/error-type.rkt"
         "../process/run.rkt")

;; path-string -> string, the target text of the link at that path.
;; A path that is not a link, and a link whose target cannot be read,
;; are refusals: the caller hashes a tree, and a tree it cannot read
;; has no address.
(define (read-link-target path)
  (define exe
    (or (find-executable-path "readlink")
        (raise-pm-error 'config 'tree-hash "readlink is not on PATH"
                        #:fields `(("path" . ,path))
                        #:hint "the link cannot be read, so the address cannot be computed")))
  (define res
    (spawn-and-wait exe (list path)
                    #:cwd (path->string (path-only path))
                    #:kind 'config #:operation "read-link"))
  (unless (zero? (result-exit res))
    (raise-pm-error 'config 'tree-hash "link target is unreadable"
                    #:fields `(("path" . ,path))
                    #:hint "the address cannot be computed, so the build must run"))
  (string-trim (string-join (result-stdout-lines res) "\n")))

(provide read-link-target)
