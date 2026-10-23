#lang racket/base
;; load.rkt — where the meaning side is reached; the one call that asks it.
;; The meaning side is the Racket program in racket-entry.rkt. D-008 in the
;; root DECISIONS.org says Racket is baked into the binary and loads nothing
;; at startup, and that the phone test confirms it or forces the external
;; process fallback. The phone cannot bake a binary, so the meaning side
;; runs as an external process and speaks one line of JSON per message over
;; the wire in protocol.rkt. The transport is in transport.rkt: one request
;; file, one answer file, one child.
;; Requires: the wire below and the machine seam.

(require racket/runtime-path
         "protocol.rkt"
         "transport.rkt"
         "../machine/directories.rkt")

;; entry-name is the meaning side's own file, named relative to this
;; directory: a path that holds a space cannot be opened from the command
;; line, so the child is started in this directory and the name stays short.
(define entry-name "racket-entry.rkt")

;; join-dir is the directory this module lives in: the child is started
;; there, so the child's own relative requires resolve. The load relative
;; directory is #f for a module reached this way, so the runtime path
;; speaks instead.
(define-runtime-path join-dir ".")

;; ask sends one request to the meaning side and returns its response.
;; The wire carries one line each way.
(define (ask op args)
  (call-over-wire (racket-bin) (list entry-name)
                  (hasheq 'op op 'args args) join-dir))

;; Where the meaning side lives and how it is asked.
(provide ask
         entry-name
         join-dir)
