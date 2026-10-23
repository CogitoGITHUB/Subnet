#lang racket/base
;; One job: the explorer check — the panel holds every command of the
;; table, and every key of the keymaps names a command that exists.
;; Registered in plan/package-tree.org; lands with the editor's keymap
;; explorer (the multiplexer TODO item 15).
;;
;; The panel is drawn from the tables, so it cannot be wrong about a
;; command that is there. What can go wrong is the other way: a command
;; of the table that the panel forgot, or a key that names a command
;; that does not exist. Both are checked here, against the real tables.

(require racket/list
         racket/set
         racket/string
         "../editor/src/commands/commands.rkt"
         "../editor/src/dashboard/explorer.rkt"
         "../editor/src/routes/keymaps.rkt")

;; panel-commands answers the commands the panel names: the commands of
;; the table that are in the panel's lines.
(define panel-commands
  (for/set ([line (in-list (explorer-lines))]
             #:when (regexp-match #rx"-> +([^ ]+)$" line))
    (cadr (regexp-match #rx"-> +([^ ]+)$" line))))

;; typed-commands answers the commands the panel names as the ones a
;; person types: the lines that name a command and no key.
(define typed-commands
  (for/set ([line (in-list (explorer-lines))]
             #:when (and (not (regexp-match #rx"-> " line))
                         (regexp-match #rx"^ +[^ ]+$" line)))
    (string-trim (cadr (regexp-match #rx"^ +([^ ]+)$" line)))))

;; table-commands answers the names of the commands the table holds. The
;; table is read as it stands: a command that was added when its module
;; was loaded is a command the editor really holds.
(define table-commands
  (sort (hash-keys commands) string<?))

;; missing-commands answers the commands of the table that the panel
;; does not name at all: the ones a key runs and the ones a person
;; types.
(define missing-commands
  (for/list ([name (in-list table-commands)]
             #:unless (or (set-member? panel-commands name)
                          (set-member? typed-commands name)))
    name))

;; unknown-key-commands answers the keys that name a command the table
;; does not hold.
(define unknown-key-commands
  (append*
   (for/list ([layer (in-list editor-layers)])
     (for/list ([binding (in-list (keys-of layer))]
                #:unless (member (cadr binding) table-commands))
       (list layer (car binding) (cadr binding))))))

;; run-check answers what happened, and the exit code says it too.
(define (run-check)
  (define missing missing-commands)
  (define unknown unknown-key-commands)
  (if (and (null? missing) (null? unknown))
      (begin
        (printf "OK explorer-check — ~a commands in the table, every one of them is in the panel, and every key names a command that exists\n"
                (length table-commands))
        (exit 0))
      (begin
        (for ([name (in-list missing)])
          (printf "EXPLORER — the command ~a is in the table and not in the panel\n" name))
        (for ([entry (in-list unknown)])
          (printf "EXPLORER — the key ~a in the layer ~a names the command ~a, and the command table does not hold it\n"
                  (second entry) (first entry) (third entry)))
        (exit 1))))

;; The check, for the dispatcher above.
(module+ main
  (run-check))
