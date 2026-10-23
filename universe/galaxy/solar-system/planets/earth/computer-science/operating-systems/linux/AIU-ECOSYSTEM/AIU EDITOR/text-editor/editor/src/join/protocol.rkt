#lang racket/base
;; One job: the wire shape — one request and one response, each one line of
;; JSON. Registered in plan/package-tree.org; lands with TODO item 2.
;;
;; The hot path and the meaning side speak only this shape. One line per
;; message, so a message never waits for the next one to be complete, and a
;; reader always knows where a message ends.

(require json)

;; A request is one operation and its arguments. The operation is a name, not
;; a number, so the wire can be read by a person and by a tool alike.
(struct request (op args) #:transparent)

;; A response is the answer to one request: whether it worked, and the data
;; it carries. A failure carries the data of the failure.
(struct response (ok data) #:transparent)

;; write-request writes one request as one line and flushes it, so the other
;; side never waits on a buffer.
(define (write-request port op args)
  (write-message port (hasheq 'op op 'args args)))

;; read-request reads one request line and answers the request it holds. It
;; answers #f at the end of the input, and it refuses a line that is not a
;; request: a wrong line is a wrong wire, and it must not be guessed at.
(define (read-request port)
  (define line (read-line port 'any))
  (cond
    [(eof-object? line) #f]
    [else
     (define value (string->jsexpr line))
     (unless (and (hash? value) (hash-has-key? value 'op))
       (error 'protocol-refused
              "a line on the wire is not a request: ~a" line))
     (request (hash-ref value 'op) (hash-ref value 'args (hasheq)))]))

;; write-response writes one response as one line and flushes it.
(define (write-response port ok data)
  (write-message port (hasheq 'ok (if ok #t #f) 'data data)))

;; read-response reads one response line and answers the response it holds.
;; It answers #f at the end of the input.
(define (read-response port)
  (define line (read-line port 'any))
  (if (eof-object? line)
      #f
      (let* ([value (string->jsexpr line)]
             [ok (hash-ref value 'ok #f)])
        (response (if (eq? ok #t) #t #f) (hash-ref value 'data #f)))))

;; write-message writes one JSON value as one line and flushes it.
(define (write-message port value)
  (displayln (jsexpr->string value) port)
  (flush-output port))

;; The wire shape, for every area that talks over it.
(provide request
         response
         request-op
         request-args
         response-ok
         response-data
         write-request
         read-request
         write-response
         read-response
         write-message)
