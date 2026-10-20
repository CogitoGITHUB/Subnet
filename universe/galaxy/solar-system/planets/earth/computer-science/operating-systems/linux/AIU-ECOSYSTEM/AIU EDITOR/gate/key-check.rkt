#lang racket/base
;; One job: the key check — every key in the keymaps is a key the hot
;; path can name, and every name it produces is one the keymaps know.
;; Registered in plan/package-tree.org; lands with TODO item 6.
;;
;; The two sides must agree: the decoding is Rust and the keymaps are
;; Racket, and a key that one side names and the other does not is a
;; key that never runs. The check asks the hot path how each key is
;; spelled and then what those bytes are, and the name that comes back
;; must be the name that went in.
;;
;; A key may be a SEQUENCE of keys, so the check walks each key of the
;; sequence and puts the bytes of all of them together.
;;
;; The check runs from the gate directory, so the package is reached by a
;; relative path: a module path that holds a space cannot be opened by
;; an absolute one on this Racket.

(require racket/list
         racket/string
         "../editor/src/routes/keyboard.rkt"
         "../editor/src/routes/keymaps.rkt"
         "../editor/src/routes/routes.rkt")

;; bytes-of answers the bytes of one key, the way a terminal sends them:
;; the hot path is asked for the bytes of each key of the sequence, and
;; the bytes are put together.
(define (bytes-of key)
  (define parts
    (for/list ([name (in-list (sequence-of key))])
      (key-bytes name)))
  (if (ormap (lambda (part) (string=? part "")) parts)
      #f
      (string-join parts "")))

;; check-key answers what is wrong with one key, or nothing when the key
;; is in order. The two sides must agree on the name, and the name must
;; be one the keymap holds.
(define (check-key layer key)
  (define hex (bytes-of key))
  (cond
    [(not hex)
     (format "the hot path does not know the key ~a of the layer ~a" key layer)]
    [else
     (define names (key-names (hex->bytes hex)))
     (cond
       [(null? names)
        (format "the hot path did not name the key ~a of the layer ~a" key layer)]
       [(not (string=? (string-join names " ") key))
        (format "the hot path named the key ~a of the layer ~a as ~a"
                key layer (string-join names " "))]
       [(not (binding-of layer key))
        (format "the key ~a of the layer ~a is not in the keymap" key layer)]
       [else #f])]))

;; main checks the keys and answers what is wrong, one line per fault.
;; It exits non-zero when a fault is found.
(define (main)
  (define keys
    (for*/list ([layer (in-list editor-layers)]
                [binding (in-list (keys-of layer))])
      (cons layer (car binding))))
  (define faults
    (filter values
            (for/list ([entry (in-list keys)])
              (check-key (car entry) (cdr entry)))))
  (if (null? faults)
      (begin
        (printf "OK key-check — ~a keys checked, the decoder and the keymaps agree on every one\n"
                (length keys))
        (exit 0))
      (begin
        (for-each (lambda (fault) (printf "KEY — ~a\n" fault)) faults)
        (printf "KEY — ~a faults in ~a keys\n" (length faults) (length keys))
        (exit 1))))

;; The check, for the dispatcher above.
(module+ main
  (main))
