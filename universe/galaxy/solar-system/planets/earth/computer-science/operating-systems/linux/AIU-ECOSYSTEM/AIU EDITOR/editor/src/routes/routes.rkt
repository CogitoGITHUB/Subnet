#lang racket/base
;; One job: the routing — which layer sees a key first. The shape is the
;; contract's (AIU-ECOSYSTEM/contract/key-routing.org): the focused
;; program sees a key first, then the editor's own layers, and the
;; multiplexer's reserved prefix applies everywhere.
;;
;; The editor owns its own half of that shape. The multiplexer owns the
;; terminals and the prefix; the programs in the panes own their own
;; keys. This file is what the editor answers: given a key, the keys the
;; focused program wants, and the editor's layer, which layer saw the
;; key and what it meant.
;;
;; The reserved prefix is a key no layer may bind: the multiplexer keeps
;; it, and a route that collides with it is refused. The check for that
;; is beside this file, in the gate.
;;
;; Registered in plan/package-tree.org; lands with TODO item 4.

(require racket/list
         racket/string
         "keymaps.rkt")

;; routing is what the routing answers: the key, the layer that saw it,
;; and what it meant there. The meaning is a command name, a text, or
;; nothing when the key was not meant for anyone.
(struct routing (key owner meaning) #:transparent)

;; layers are the layers a key can be seen by, in the order they see it.
;; The multiplexer is first because its prefix applies everywhere: the
;; prefix is the multiplexer's own key, so it is taken before any layer
;; below it can claim it. The program comes before the editor's own
;; layers, and a key nobody wants is claimed by nobody.
(define layers '("multiplexer" "program" "editor" "unclaimed"))

;; named-keys are the keys that name a key of the keyboard rather than a
;; character.
(define named-keys
  '("escape" "return" "tab" "space" "backspace" "delete"
    "up" "down" "left" "right" "home" "end" "pageup" "pagedown"))

;; text-of answers the text one key carries, or nothing when the key
;; carries no text. A key named with a prefix that names a modifier
;; (C- for control, M- for alt, S- for shift) is a command, not text.
(define (text-of key)
  (cond
    [(member key named-keys) key]
    [(or (string-prefix? key "C-")
         (string-prefix? key "M-")
         (string-prefix? key "S-")) #f]
    [(= (string-length key) 1) key]
    [else #f]))

;; route-key answers which layer saw one key. The program-claims are the
;; keys the focused program wants; the layer is the editor's own layer
;; the editor is in.
(define (route-key key program-claims layer)
  (cond
    [(string=? key reserved-prefix)
     (routing key "multiplexer" #f)]
    [(member key program-claims)
     (routing key "program" #f)]
    [else
     (define bound (binding-of layer key))
     (cond
       [bound (routing key "editor" bound)]
       [(string=? layer "insert")
        (define text (text-of key))
        (if text (routing key "editor" text) (routing key "unclaimed" #f))]
       [else (routing key "unclaimed" #f)])]))

;; route-walk answers the routing of every key of a list, in the order
;; the keys were given. This is the walk the contract asks for: one
;; answer per key, so a reader can see which layer took each one.
(define (route-walk keys program-claims layer)
  (map (lambda (key) (route-key key program-claims layer)) keys))

;; route-line answers one line of text for one routing answer, so the
;; walk reads the same way every time it is printed.
(define (route-line answer)
  (define key (routing-key answer))
  (define owner (routing-owner answer))
  (define meaning (routing-meaning answer))
  (format "~a -> ~a ~a"
          key
          owner
          (if meaning (format "~a" meaning) "-")))

;; route-commands answers every route of every layer as the layer, the
;; key and the command it runs. The keys of a layer are pairs — a key and
;; the command it runs — so the key is the first of the pair and the
;; command the second.
(define (route-commands)
  (append*
   (for/list ([layer (in-list editor-layers)])
     (for/list ([binding (in-list (keys-of layer))])
       (list layer (car binding) (cadr binding))))))

;; reserved-prefix-collisions answers the routes that collide with the
;; reserved prefix: a key the multiplexer keeps may not be bound by any
;; layer of the editor. The gate refuses the editor when this is not
;; empty.
(define (reserved-prefix-collisions)
  (append*
   (for/list ([layer (in-list editor-layers)])
     (for/list ([binding (in-list (keys-of layer))]
                #:when (string=? (car binding) reserved-prefix))
       (list layer (car binding))))))

;; The routing, for the entry above it and the gate beside it.
(provide routing
         routing-key
         routing-owner
         routing-meaning
         route-key
         route-walk
         route-line
         route-commands
         reserved-prefix-collisions
         reserved-prefix
         keys-of
         editor-layers
         layers)
