#lang racket/base
;; One job: the live session — the keys from the terminal, each one
;; routed and run. Registered in plan/package-tree.org; lands with TODO
;; item 6.
;;
;; The loop is action based: it reads the next byte and the read waits
;; for it. There is NO timer anywhere — not for a key, not for a chord,
;; not for a trigger. A key that is the start of a sequence waits for the
;; next key, and the next key is an action.
;;
;; The decoding is the hot path's job (rule 09): the bytes go over the
;; seam and the hot path answers the name of each key and how many
;; bytes it took. The keymaps and the routing are here (rule 13), so
;; this file looks the name up and runs the command the route names.
;;
;; The terminal is given back exactly as it was found, even when the
;; editor was killed: the settings are saved before the terminal goes
;; raw, and the next run gives it back before it goes raw again.

(require racket/list
         racket/port
         racket/string
         "../narration/print-console.rkt"
         "../commands/commands.rkt"
         "../join/hot-path.rkt"
         "../join/protocol.rkt"
         "../machine/terminal.rkt"
         "../routes/keyboard.rkt"
         "../routes/keymaps.rkt"
         "../routes/routes.rkt")

;; live-session runs the live session on a file: the terminal goes raw,
;; the keys are read and run, and the terminal is given back when the
;; session ends.
(define (live-session file journal)
  (define session (make-session file journal))
  (raw-mode)
  (dynamic-wind
    (lambda () #f)
    (lambda () (key-loop session (current-input-port)))
    (lambda () (restore-settings))))

;; outcome is what one round of the loop did: the bytes that are left
;; for the next round, and whether the session goes on. The bytes are
;; the word "wait" when the keys so far are the start of a sequence and
;; the next key must arrive.
(struct outcome (rest go-on?) #:transparent)

;; key-loop reads the bytes that arrive and runs what they mean. The
;; bytes that have arrived so far are kept: the hot path is asked about
;; all of them, so a key that is the start of a sequence is seen whole.
(define (key-loop session port)
  (let loop ([buffer '()])
    (define byte (read-byte port))
    (unless (eof-object? byte)
      (define more (append buffer (list byte)))
      (define result (act-on session more))
      (cond
        [(eq? (outcome-rest result) 'wait)
         (loop more)]
        [(outcome-go-on? result)
         (loop (outcome-rest result))]
        [else (void)]))))

;; act-on runs what the bytes mean and answers what the round did: the
;; bytes that are left for the next round, and whether the session goes
;; on.
(define (act-on session buffer)
  (define runs (key-runs buffer))
  (cond
    [(null? runs)
     ;; The bytes hold no whole key yet: the next byte is read, and the
     ;; read waits for it. No clock decides this.
     (outcome 'wait #t)]
    [else
     (define names (map car runs))
     (define layer (the-layer session))
     (define written (string-join names " "))
     (cond
       [(binding-of layer written)
        (outcome (drop-bytes buffer runs) (run-it session (binding-of layer written)))]
       [(prefix-of? layer names)
        ;; The keys so far are the start of a sequence: the next key is
        ;; waited for, and the wait is an action.
        (outcome 'wait #t)]
       [(string=? layer "write")
        ;; In the write layer the keys are text.
        (outcome (drop-bytes buffer runs)
                 (run-it session (string-append "type " written)))]
       [else
        ;; The first key means nothing to anybody: it is said out loud
        ;; and the rest of the bytes are kept.
        (print-line (format "no key is bound to ~a" (car names)))
        (outcome (drop-bytes buffer (list (car runs))) #t)])]))

;; run-it runs one command and answers whether the session goes on. The
;; answer of the command is printed, so a person sees what the key did.
(define (run-it session line)
  (define answer (run-command session line))
  (unless (string=? (cdr answer) "")
    (print-line (cdr answer)))
  (car answer))

;; drop-bytes answers the bytes that are left when the keys that were
;; run are taken out of the buffer.
(define (drop-bytes buffer runs)
  (define taken (for/sum ([run (in-list runs)]) (cdr run)))
  (if (>= taken (length buffer))
      '()
      (drop (length buffer) taken buffer)))

;; The live session, for the entry above it.
(provide live-session)
