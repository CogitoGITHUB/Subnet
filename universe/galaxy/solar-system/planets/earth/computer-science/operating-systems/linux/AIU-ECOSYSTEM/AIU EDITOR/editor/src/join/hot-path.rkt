#lang racket/base
;; One job: the call that asks the hot path — the Rust side of the seam.
;; The hot path is the binary that holds the text state and the journal.
;; It is asked over the same file wire the meaning side uses: one request
;; file, one answer file, one child. The child holds no session of its
;; own, so every question starts it and ends it; the state lives in the
;; file and in the journal.

(require "transport.rkt"
         "../machine/directories.rkt")

;; ask-hot sends one request to the hot path and answers its response.
;; The arguments are names and values, all strings: the hot path's reader
;; stays small and never guesses.
(define (ask-hot op args)
  (call-over-wire (hot-path-bin) '() (hasheq 'op op 'args args)))

;; The call that asks the hot path.
(provide ask-hot)
