#lang racket/base
;; One job: the keyboard — the bytes of a key become the name of a key,
;; and the name becomes the command it runs. The decoding is the hot
;; path's job (rule 09) and the keymaps are here (rule 13).
;;
;; The keymap is the table of a layer: a key and the command it runs.
;; The command is a NAME from the command table, never a function, so
;; the table can be read and checked on its own.
;;
;; A key is named the way the terminal names it: the characters for a
;; plain key, C- for control, M- for alt, S- for shift, and a word for
;; a named key — escape, return, tab, space, backspace, delete, up,
;; down, left, right, home, end, pageup, pagedown, and f1 to f12.
;;
;; Registered in plan/package-tree.org; lands with TODO item 6.

(require racket/string
         "../join/hot-path.rkt"
         "../join/protocol.rkt"
         "keymaps.rkt")

;; key-names asks the hot path what the bytes are, and answers the names
;; of the keys they hold. The bytes travel as hex, because the wire
;; carries text and a key may be any byte at all.
(define (key-names bytes)
  (define answer (ask-hot "keys" (hasheq 'bytes (bytes->hex bytes))))
  (if (response-ok answer)
      (let* ([data (response-data answer)]
             [names (hash-ref data 'names "")])
        (if (string=? names "") '() (string-split names " ")))
      '()))

;; bytes->hex answers the hex of some bytes: two digits for each byte,
;; so the wire can carry a key that is not a character.
(define (bytes->hex bytes)
  (string-join
   (for/list ([b (in-list bytes)])
     (format "~a~a" (if (< b 16) "0" "") (number->string b 16)))
   ""))

;; route-of-key answers the layer that sees one key, and what it means
;; there: the routing (routes.rkt) decides the layer and the keymap
;; (keymaps.rkt) says what the key runs. A key nobody wants is claimed
;; by nobody, and the answer says so.
(define (route-of-key key program-claims layer)
  (define bound (binding-of layer key))
  (cond
    [bound (list layer bound)]
    [(and (string=? layer "insert") (text-key? key)) (list layer key)]
    [else (list "unclaimed" "")]))

;; text-key? answers whether a key carries text rather than a command: a
;; plain character does, and a key with a modifier or a name does not.
(define (text-key? key)
  (and (= (string-length key) 1)
       (not (string-prefix? key "C-"))
       (not (string-prefix? key "M-"))
       (not (string-prefix? key "S-"))))

;; key-bytes asks the hot path how a key name is spelled: the bytes a
;; terminal sends for that key. It answers nothing when the decoder does
;; not know the name, and the check says so rather than guessing.
(define (key-bytes name)
  (define answer (ask-hot "key-bytes" (hasheq 'name name)))
  (if (response-ok answer)
      (hash-ref (response-data answer) 'bytes "")
      ""))

;; hex->bytes answers the bytes of a run of hex digits: two digits for
;; each byte, so a key that is not a character can travel.
(define (hex->bytes hex)
  (define digits (filter (lambda (c) (char-hex-digit? c)) (string->list hex)))
  (let loop ([at 0] [bytes '()])
    (if (>= (+ at 1) (length digits))
        (reverse bytes)
        (loop (+ at 2)
              (cons (string->number (substring hex at (+ at 2)) 16) bytes)))))

;; char-hex-digit? answers whether a character is a hex digit.
(define (char-hex-digit? c)
  (or (char-numeric? c) (char<=? #\a c) (char<=? c #\f) (char<=? #\A c) (char<=? c #\F)))

;; The keyboard, for the entry above it.
(provide key-names
         key-bytes
         bytes->hex
         hex->bytes
         route-of-key
         text-key?)
