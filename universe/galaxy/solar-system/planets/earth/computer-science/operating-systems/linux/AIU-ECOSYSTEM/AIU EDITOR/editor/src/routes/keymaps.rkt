#lang racket/base
;; One job: the mapping tables, as data — the editor's own keys and the
;; layers they belong to. Registered in plan/package-tree.org; lands with
;; TODO item 4.
;;
;; The tables are data and not code: the routing reads them, the gate
;; checks them, and a person can read what the editor does with a key
;; without reading a function.
;;
;; A key is named the way the terminal names it: the characters for a
;; plain key, C- for control, M- for alt, S- for shift, and a word for a
;; named key — escape, return, tab, space, backspace, delete, up, down,
;; left, right, home, end, pageup, pagedown, and f1 to f12.

;; reserved-prefix is the key the multiplexer keeps for itself. It applies
;; everywhere, so the editor never binds it: a binding that collides with
;; it is refused by the route-collision stage of the gate.
(define reserved-prefix "C-b")

;; editor-layers are the editor's own layers, in the order the routing
;; looks at them. The layer the editor is in answers first.
(define editor-layers '("normal" "insert"))

;; normal-keys are the keys of the normal layer: the key and the command
;; it runs. The command is a name from the command table, never a
;; function, so the table can be read and checked on its own.
(define normal-keys
  '(("C-s" "save")
    ("C-q" "quit")
    ("C-l" "show")
    ("C-h" "help")))

;; insert-keys are the keys of the insert layer. In this layer the keys
;; are text, so the layer holds no table: the routing answers the text
;; itself.
(define insert-keys '())

;; keymaps is the whole table: a layer name and the keys of that layer.
;; The tables are put in with cons, not with a quote: a quoted list would
;; hold the NAMES of the tables, not the tables themselves.
(define keymaps
  (list (cons "normal" normal-keys)
        (cons "insert" insert-keys)))

;; keys-of answers the keys of one layer, or nothing when the table holds
;; no layer by that name. The keys of a layer are pairs: a key and the
;; command it runs.
(define (keys-of layer)
  (define found (assoc layer keymaps))
  (if found (cdr found) '()))

;; binding-of answers the command one key runs in one layer, or nothing
;; when the layer binds no such key. A binding is a pair of a key and a
;; command, so the command is the second of the two.
(define (binding-of layer key)
  (define found (assoc key (keys-of layer)))
  (if found (cadr found) #f))

;; The tables, for the routing above them and the gate beside them.
(provide reserved-prefix
         editor-layers
         normal-keys
         insert-keys
         keymaps
         keys-of
         binding-of)
