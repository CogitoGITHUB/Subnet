#lang racket/base
;; One job: the stop switch — every running agent session for this
;; project stops (D-010). Registered in plan/package-tree.org; lands with
;; TODO item 12.
;;
;; It lives in the MACHINE area, below the send area, because the send
;; area asks it on every call and an area may only reach DOWNWARD.
;;
;; The switch is COARSE: it stops every agent session for this project,
;; and there is no per-session and no per-agent toggle. That is the
;; honest one until a real need for finer granularity appears.
;;
;; The switch is a file in the state directory: the file is there, the
;; sessions stop. Nothing polls it in a loop and nothing ticks: the
;; adapter asks the switch on every call, and a call is an action.
;;
;; Registered in plan/package-tree.org; lands with TODO item 12.

(require racket/file
         racket/string
         "directories.rkt")

;; stop-file is the switch itself: while the file is there, the agent
;; sessions for this project stop.
(define stop-file
  (build-path (state-dir) "stop"))

;; stopped? answers whether the switch is thrown.
(define (stopped?)
  (file-exists? stop-file))

;; throw-switch throws the switch: the file is written, and every agent
;; session for this project stops at its next call.
(define (throw-switch)
  (ensure-dir (state-dir))
  (call-with-output-file stop-file
    (lambda (port) (display "the stop switch is thrown\n" port))
    #:exists 'truncate)
  #t)

;; clear-switch clears the switch: the file is gone, and the agent
;; sessions may run again.
(define (clear-switch)
  (when (file-exists? stop-file)
    (delete-file stop-file))
  #f)

;; The stop switch, for the adapter beside it.
(provide stop-file
         stopped?
         throw-switch
         clear-switch)
