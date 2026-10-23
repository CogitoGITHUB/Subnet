#lang racket/base
;; One job: the keymap explorer — the editor's own keys, drawn from the
;; editor's own tables.
;;
;; This is the editor's half of the multiplexer's keymap explorer (the
;; design is in AIU TERMINAL MULTIPLEXER/plan/keymap-explorer.org): the
;; same model, the editor's own mode names and the editor's own keys. The
;; two programs share the model and not the code.
;;
;; The panel is drawn from the keymaps and from the command table, so a
;; binding cannot be shown wrongly: there is nothing to show it wrongly
;; from. Every command of the table is in the panel — the ones a key runs
;; and the ones a person types — so every command is reachable through
;; this table.
;;
;; The command "explorer" is added to the command table when this module
;; is loaded, so the key that opens the panel runs it, and the gate's
;; route check sees it.

(require racket/list
         racket/string
         "../commands/commands.rkt"
         "../routes/keymaps.rkt")

;; explorer-lines answers the lines of the panel: every layer with the
;; keys it binds and the command each key runs, and then the commands
;; that no key runs, so every command of the table is in the panel.
(define (explorer-lines)
  (define lines (list "the keymap — the editor's own keys"))
  (for ([layer (in-list editor-layers)])
    (set! lines
          (append lines
                  (list (format "  ~a:" layer))))
    (for ([binding (in-list (keys-of layer))])
      (set! lines
            (append lines
                    (list (format "    ~a  ->  ~a"
                                  (car binding)
                                  (cadr binding)))))))
  (define bound
    (map cadr
         (append* (for/list ([layer (in-list editor-layers)])
                    (keys-of layer)))))
  ;; The table is read as it stands, so a command that was added later —
  ;; a plugin's command, for instance — is in the panel too.
  (define typed
    (filter (lambda (name) (not (member name bound)))
            (sort (hash-keys commands) string<?)))
  (when (not (null? typed))
    (set! lines (append lines (list "  the commands you can type:")))
    (for ([name (in-list typed)])
      (set! lines (append lines (list (format "    ~a" name))))))
  (append lines (list "  every command of the table is in this panel")))

;; command-explorer answers the panel: one line per line of it.
(define (command-explorer session words)
  (cons #t (string-join (explorer-lines) "\n")))

;; The command is added to the table here, so the key that opens the
;; panel runs the panel and the gate sees the same table the editor does.
(hash-set! commands "explorer" command-explorer)

;; The panel, for the dashboard and for the gate beside it.
(provide explorer-lines
         command-explorer)
