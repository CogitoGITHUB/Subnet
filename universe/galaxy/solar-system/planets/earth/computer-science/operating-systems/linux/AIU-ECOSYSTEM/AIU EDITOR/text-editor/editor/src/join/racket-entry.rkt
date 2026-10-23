#lang racket/base
;; One job: the meaning side's entry — one request line in, one response line
;; out. Registered in plan/package-tree.org; lands with TODO item 2.
;;
;; The voice of the program goes to stderr, never to stdout: stdout carries
;; the wire and nothing else, so a reader of the wire never sees a log line.

(require "protocol.rkt"
         "../errors/err.rkt"
         "../errors/raise.rkt"
         "../narration/narration.rkt")

;; wire-in is the request channel: the standard input, taken before anything
;; is done to it.
(define wire-in (current-input-port))

;; wire-out is the response channel: the standard output, taken before the
;; voice is moved to stderr.
(define wire-out (current-output-port))

;; answer-ping says the meaning side is alive and names itself.
(define (answer-ping args)
  (hasheq 'pong #t 'who "the meaning side"))

;; answer-echo gives the arguments back, which proves the wire carries them
;; and does not lose them.
(define (answer-echo args)
  (hasheq 'echo args))

;; operations is the table: one name, one function. It holds what exists
;; today and nothing more: the commands, routes and models areas are not
;; written yet, so there is nothing else for the meaning side to answer.
(define operations
  (hash "ping" answer-ping
        "echo" answer-echo))

;; answer-op runs one operation and answers the data it gives.
(define (answer-op op args)
  (define handler (hash-ref operations op #f))
  (if handler
      (handler args)
      (error-of 'err-unknown-op "the meaning side" op
                (format "there is no operation named ~a" op)
                "ask for one of: ping, echo")))

;; serve reads one request, answers it, and stops: one request, one
;; response, and no process left behind.
(define (serve)
  (define asked (read-request wire-in))
  (cond
    [(not asked) #f]
    [else
     (define answered
       (with-handlers
           ([exn:fail?
             (lambda (e)
               (define record (if (exn:fail:editor? e) (exn:fail:editor-err e) #f))
               (if record
                   (response #f (hasheq 'kind (symbol->string (err-kind record))
                                        'what (err-what record)
                                        'what_to_do (err-what-to-do record)))
                   (response #f (hasheq 'kind "err-unexpected"
                                        'what (exn-message e)
                                        'what_to_do "read the stderr of the meaning side"))))])
         (response #t (answer-op (request-op asked) (request-args asked)))))
     (write-response wire-out (response-ok answered) (response-data answered))
     answered]))

;; main moves the voice to stderr and serves one request. It answers
;; nothing on stdout but the wire: the reply is written by serve, and the
;; value of this function is void, so the command line prints no echo and
;; the wire keeps exactly one line per message.
(define (main)
  (parameterize ([current-output-port (current-error-port)])
    (note "the meaning side"
          "waiting for a request on the wire; it ends on the answer")
    (serve)
    (void)))

(module+ main
  (main))

;; The entry, for the loader that reaches it.
(provide serve
         answer-op
         operations)
