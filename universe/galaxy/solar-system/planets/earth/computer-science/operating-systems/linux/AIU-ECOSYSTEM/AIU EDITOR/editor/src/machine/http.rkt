#lang racket/base
;; One job: the one HTTP client — one call over the loopback socket,
;; and a stream that stays open for the agent's events.
;;
;; It lives in the MACHINE area, below the send area, because the send
;; area asks it on every call and an area may only reach DOWNWARD.
;;
;; This Racket has no http collection of its own, so the client is
;; written here: the request line, the headers, the body, and the reply
;; read back the same way. It speaks HTTP/1.1 on the loopback and
;; nothing else — no redirect, no cookie jar, no pool. The agent's
;; server is on the loopback, so plain HTTP is enough.
;;
;; There is NO TIMER anywhere in it: a call waits for the reply and a
;; stream waits for the next line, and both waits end when the other
;; side speaks (rule 04).
;;
;; Registered in plan/package-tree.org; lands with TODO item 9.

(require net/url
         racket/bytes
         racket/list
         racket/port
         racket/string
         racket/tcp)

;; http-reply is what one call answers: the status code, the headers and
;; the body. The headers are a list of name/value pairs, in the order
;; the server sent them.
(struct http-reply (status headers body) #:transparent)

;; http-stream is a reply that stays open: the port the body comes
;; from, whether the body is chunked, and the buffer of the text that
;; was taken off the framing already. The agent's event feed is one
;; such stream.
(struct http-stream (port chunked? buffer) #:transparent)

;; http-call makes one call and answers the reply, or nothing when the
;; server cannot be reached. A server that cannot be reached is not
;; swallowed: the caller names it.
(define (http-call base-url method path headers body)
  (with-handlers ([exn:fail? (lambda (why) #f)])
    (define u (string->url base-url))
    (define-values (in out) (tcp-connect (url-host u) (url-port u)))
    (dynamic-wind
     void
     (lambda ()
       (write-request out method path headers body #f)
       (define status (read-status in))
       (define reply-headers (read-headers in))
       (http-reply status reply-headers (read-body in reply-headers)))
     (lambda () (close-input-port in)))))

;; http-open-stream opens a reply that stays open and answers the
;; stream, or nothing when the server cannot be reached. The caller
;; reads the stream line by line; the read waits for the feed.
(define (http-open-stream base-url method path headers)
  (with-handlers ([exn:fail? (lambda (why) #f)])
    (define u (string->url base-url))
    (define-values (in out) (tcp-connect (url-host u) (url-port u)))
    (write-request out method path headers "" #t)
    (define status (read-status in))
    (define reply-headers (read-headers in))
    (if (and (>= status 200) (< status 300))
        (http-stream in (chunked-body? reply-headers) (box ""))
        (begin (close-input-port in) #f))))

;; write-request writes one request: the line, the headers, the body.
;; A call says close when it is done; a stream says keep-alive and stays
;; open.
(define (write-request out method path headers body keep-alive?)
  (fprintf out "~a ~a HTTP/1.1\r\n" method path)
  (for ([h (in-list headers)])
    (fprintf out "~a: ~a\r\n" (car h) (cdr h)))
  (when (not (string=? body ""))
    (fprintf out "Content-Length: ~a\r\n" (string-length body)))
  (fprintf out "Connection: ~a\r\n\r\n" (if keep-alive? "keep-alive" "close"))
  (when (not (string=? body ""))
    (display body out))
  (flush-output out))

;; read-status reads the first line of a reply and answers the status
;; code. A line that is not a status line is a failure of the server,
;; and the code is zero: the caller says the server spoke nonsense.
(define (read-status in)
  (define line (read-line in))
  (if (eof-object? line)
      0
      (status-of-line line)))

;; status-of-line answers the status code of a status line. A line that
;; is not a status line is a failure of the server, and the code is
;; zero: the caller says the server spoke nonsense.
(define (status-of-line line)
  (define parts (string-split line " "))
  (if (< (length parts) 2)
      0
      (string->number (cadr parts))))

;; read-headers reads the header block and answers the headers as a list
;; of name/value pairs. The blank line that ends the block is consumed
;; here, so the body starts right after it.
(define (read-headers in)
  (let loop ([out '()])
    (define line (read-line in))
    (cond
      [(eof-object? line) (reverse out)]
      [(string=? (string-trim line) "") (reverse out)]
      [else (loop (cons (header-pair line) out))])))

;; header-pair answers the name and the value of one header line.
(define (header-pair line)
  (define parts (string-split line ":"))
  (if (< (length parts) 2)
      (cons "" "")
      (cons (string-trim (car parts))
            (string-trim (string-join (cdr parts) ":")))))

;; header-value answers the value of a header by its name, in lower
;; case, or nothing when the reply does not carry it.
(define (header-value headers name)
  (define found
    (findf (lambda (h) (string=? (string-downcase (car h)) (string-downcase name)))
           headers))
  (if found (cdr found) #f))

;; chunked-body? answers whether the body of a reply is chunked: the
;; server sends it that way when the length is not known in advance,
;; and the framing has to be taken off before the text is read.
(define (chunked-body? headers)
  (define encoding (header-value headers "transfer-encoding"))
  (and encoding (string-contains? (string-downcase encoding) "chunked")))

;; http-stream-line answers the next line of the body of a stream, or
;; nothing when the body is done. A chunked body is decoded here, so
;; the caller reads the same lines either way: the size line and the
;; line that ends a chunk are framing, not text.
(define (http-stream-line stream)
  (if (http-stream-chunked? stream)
      (chunked-line (http-stream-port stream) (http-stream-buffer stream))
      (read-line (http-stream-port stream))))

;; chunked-line answers the next line of a chunked body, or NOTHING when
;; the body is done. The text of a chunk that has no line in it yet
;; waits in the buffer, and the next chunk is read when it is needed.
(define (chunked-line in buffer)
  (let loop ()
    (define parts (first-line (unbox buffer)))
    (if (not (null? (cdr parts)))
        (begin (set-box! buffer (cdr parts)) (car parts))
        ;; the body is done when the last chunk was read: the stream
        ;; ends there, and the end is told and not waited for. A reader
        ;; that loops on the end spins forever and burns the battery.
        (if (fill-chunk! in buffer)
            (loop)
            #f))))

;; first-line answers the first line of a text and the rest of it. The
;; rest is nothing when the text holds no line at all.
(define (first-line text)
  (let loop ([i 0])
    (cond
      [(>= i (string-length text)) (cons text "")]
      [(char=? (string-ref text i) #\newline)
       (cons (substring text 0 i) (substring text (add1 i)))]
      [else (loop (add1 i))])))

;; fill-chunk! reads one chunk of a chunked body and puts its text in
;; the buffer. The size line names how many bytes the chunk holds, and
;; the blank line after the chunk ends it.
(define (fill-chunk! in buffer)
  (define size-line (read-line in))
  (cond
    [(eof-object? size-line) (set-box! buffer "") #f]
    [(string=? (string-trim size-line) "") (fill-chunk! in buffer)]
    [else
     (define size (string->number (string-trim (car (string-split size-line ";"))) 16))
     (if (= size 0)
         (begin (set-box! buffer "") #f)
         (let ([chunk (bytes->string/utf-8 (read-bytes size in))])
           (read-line in)
           (set-box! buffer (string-append (unbox buffer) chunk))
           #t))]))

;; read-body reads the body of a reply. A chunked body is read chunk by
;; chunk, because that is how the server sends it when the length is
;; not known in advance; any other body is read to the end.
(define (read-body in headers)
  (define encoding (header-value headers "transfer-encoding"))
  (if (and encoding (string-contains? (string-downcase encoding) "chunked"))
      (read-chunks in)
      (port->string in)))

;; read-chunks reads a chunked body and answers the text of it.
(define (read-chunks in)
  (let loop ([out ""])
    (define line (read-line in))
    (cond
      [(or (eof-object? line) (string=? (string-trim line) "")) out]
      [else
       (define size (chunk-size line))
       (define chunk (if (> size 0) (bytes->string/utf-8 (read-bytes in size)) ""))
       (read-line in)
       (loop (string-append out chunk))])))

;; chunk-size answers how many bytes the chunk of a chunked body holds.
;; The size is in hex, and it may carry the extensions after a
;; semicolon.
(define (chunk-size line)
  (string->number (string-trim (car (string-split line ";"))) 16))

;; The client, for the send area above it.
(provide http-reply
         http-reply-status
         http-reply-headers
         http-reply-body
         http-stream
         http-stream-port
         http-stream-line
         http-call
         http-open-stream
         header-value)
