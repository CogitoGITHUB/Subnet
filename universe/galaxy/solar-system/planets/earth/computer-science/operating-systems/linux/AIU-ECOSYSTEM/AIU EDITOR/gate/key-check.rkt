#lang racket/base
;; One job: the key check — every key in the keymaps is a key the hot
;; path can name, and every name it produces is one the keymaps know.
;; Registered in plan/package-tree.org; lands with TODO item 6.
;;
;; The two sides must agree: the decoding is Rust and the keymaps are
;; Racket, and a key that one side names and the other does not is a
;; key that never runs. The check asks the hot path to decode the bytes
;; of every key in the keymaps, and asks that the name it answers is the
;; name the keymap holds.
;;
;; The check runs from the gate directory, so the package is reached by a
;; relative path: a module path that holds a space cannot be opened by
;; an absolute one on this Racket.

(require racket/list
         racket/string
         "../editor/src/routes/keyboard.rkt"
         "../editor/src/routes/keymaps.rkt"
         "../editor/src/routes/routes.rkt")

;; check-key answers what is wrong with one key, or nothing when the
;; key is in order. The name is walked round: the hot path is asked how
;; the key is spelled, and then what those bytes are, and the name that
;; comes back must be the name that went in. The bytes are never spelled
;; out here, so the check cannot drift from the decoder.
(define (check-key layer key)
  (define hex (key-bytes key))
  (cond
    [(string=? hex "")
     (format "the hot path does not know the key ~a of the layer ~a" key layer)]
    [else
     (define names (key-names (hex->bytes hex)))
     (cond
       [(null? names)
        (format "the hot path did not name the key ~a of the layer ~a" key layer)]
       [(not (string=? (car names) key))
        (format "the hot path named the key ~a of the layer ~a as ~a"
                key layer (car names))]
       [(not (binding-of layer key))
        (format "the key ~a of the layer ~a is not in the keymap" key layer)]
       [else #f])]))

;; main checks the keys and answers what is wrong, one line per fault.
;; It exits non-zero when a fault is found, and it says how many keys it
;; looked at, so a check that looked at nothing cannot pass quietly.
(define (main)
  (define bindings
    (for*/list ([layer (in-list editor-layers)]
                [binding (in-list (keys-of layer))])
      (list layer (car binding))))
  (define faults
    (filter (lambda (fault) (and fault (not (string=? fault ""))))
            (for/list ([binding (in-list bindings)])
              (check-key (first binding) (second binding)))))
  (if (null? faults)
      (begin
        (printf "OK key-check — ~a keys checked, the decoder and the keymaps agree on every one\n"
                (length bindings))
        (exit 0))
      (begin
        (for-each (lambda (fault) (printf "KEY — ~a\n" fault)) faults)
        (printf "KEY — ~a faults in ~a keys\n" (length faults) (length bindings))
        (exit 1))))

;; The check, for the dispatcher above.
(module+ main
  (main))
