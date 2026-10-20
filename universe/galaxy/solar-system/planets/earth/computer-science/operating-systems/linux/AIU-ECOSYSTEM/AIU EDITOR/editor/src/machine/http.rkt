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
;; THE WHOLE REPLY IS READ IN BYTES, and that is the law of this file:
;; the lines of the head and the bytes of the body come from ONE
;; reader. Racket's line reader decodes the bytes it takes, and a
;; character that is half there when the buffer ends stays half there
;; — the bytes of a body are then gone, and the framing of every chunk
;; after it breaks. Reading the reply in bytes has no decoder in it,
;; and a byte is a byte.
;;
;; THE READS WAIT FOR WHAT THEY ASKED FOR, and never for more: a read
;; that asks for a thousand bytes on a socket that carries a hundred
;; waits for the other nine hundred, and the reply that was complete
;; long ago is never read. So a line is read a byte at a time, and a
;; payload is read with the count the wire names.
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

;; byte-reader reads the bytes of a reply: the lines of the head and
;; the bytes of the body come from the same reader, so no byte is read
;; twice and no byte is left in a buffer nobody looks at.
(struct byte-reader (port buffer) #:transparent #:mutable)

;; http-stream is a reply that stays open: the port the body comes
;; from, whether the body is chunked, the reader that holds the bytes
;; already taken off the socket, and the buffer of the text that was
;; taken off the framing already. The agent's event feed is one such
;; stream.
(struct http-stream (port chunked? reader buffer) #:transparent)

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
       (define reader (new-byte-reader in))
       (define status (read-status reader))
       (define reply-headers (read-headers reader))
       (http-reply status reply-headers (read-body reader reply-headers)))
     (lambda () (close-input-port in)))))

;; http-open-stream opens a reply that stays open and answers the
;; stream, or nothing when the server cannot be reached. The caller
;; reads the stream line by line; the read waits for the feed.
(define (http-open-stream base-url method path headers)
  (with-handlers ([exn:fail? (lambda (why) #f)])
    (define u (string->url base-url))
    (define-values (in out) (tcp-connect (url-host u) (url-port u)))
    (write-request out method path headers "" #t)
    (define reader (new-byte-reader in))
    (define status (read-status reader))
    (define reply-headers (read-headers reader))
    (if (and (>= status 200) (< status 300))
        (http-stream in (chunked-body? reply-headers) reader (box ""))
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

;; new-byte-reader answers the reader of a body: the port it reads and
;; the bytes it has taken off the socket already.
(define (new-byte-reader port)
  (byte-reader port #""))

;; reader-refill! takes ONE byte off the socket into the reader's
;; buffer, and answers whether one came. One byte at a time is the
;; price of a read that waits for nothing more than it asked for.
(define (reader-refill! reader)
  (define more (read-bytes 1 (byte-reader-port reader)))
  (if (eof-object? more)
      #f
      (begin
        (set-byte-reader-buffer! reader (bytes-append (byte-reader-buffer reader) more))
        #t)))

;; reader-line answers the next line of the body, without the newline
;; and without the carriage return before it, or NOTHING when the body
;; is done. The line is taken from the bytes already read; the socket
;; is read only when the line is not complete yet.
(define (reader-line reader)
  (let loop ()
    (define buffer (byte-reader-buffer reader))
    (define index (index-of-byte buffer (char->integer #\newline)))
    (if index
        (let ([line (bytes->string/utf-8 (subbytes buffer 0 index))])
          (set-byte-reader-buffer! reader (subbytes buffer (add1 index) (bytes-length buffer)))
          (drop-carriage-return line))
        (if (reader-refill! reader)
            (loop)
            (let ([rest (byte-reader-buffer reader)])
              (set-byte-reader-buffer! reader #"")
              (if (zero? (bytes-length rest)) #f (bytes->string/utf-8 rest)))))))

;; reader-bytes answers exactly size bytes of the body: the bytes that
;; are in the buffer come first, and the socket is read until the count
;; is met. A chunk that comes short breaks the framing of every chunk
;; after it, so the bytes are read until the count is met.
(define (reader-bytes reader size)
  (let loop ([out #""])
    (define have (bytes-length out))
    (cond
      [(>= have size) (bytes->string/utf-8 (subbytes out 0 size))]
      [else
       (define buffer (byte-reader-buffer reader))
       (define take (min (- size have) (bytes-length buffer)))
       (set-byte-reader-buffer! reader (subbytes buffer take (bytes-length buffer)))
       (if (and (= take 0) (not (reader-refill! reader)))
           (bytes->string/utf-8 out)
           (loop (bytes-append out (subbytes buffer 0 take))))])))

;; reader-rest answers the bytes that are left of the body, read to the
;; end of the socket.
(define (reader-rest reader)
  (let loop ([out (byte-reader-buffer reader)])
    (set-byte-reader-buffer! reader #"")
    (define more (read-bytes 1 (byte-reader-port reader)))
    (if (eof-object? more)
        (bytes->string/utf-8 out)
        (loop (bytes-append out more)))))

;; index-of-byte answers where a byte is in a buffer, or NOTHING when
;; the buffer holds no such byte.
(define (index-of-byte buffer byte)
  (let loop ([i 0])
    (cond
      [(>= i (bytes-length buffer)) #f]
      [(= (bytes-ref buffer i) byte) i]
      [else (loop (add1 i))])))

;; drop-carriage-return answers a line without the carriage return
;; that ends it: the wire says CRLF, and the text does not need it.
(define (drop-carriage-return line)
  (define size (string-length line))
  (if (and (> size 0) (char=? (string-ref line (sub1 size)) #\return))
      (substring line 0 (sub1 size))
      line))

;; read-status reads the first line of a reply and answers the status
;; code. A line that is not a status line is a failure of the server,
;; and the code is zero: the caller says the server spoke nonsense.
(define (read-status reader)
  (define line (reader-line reader))
  (if (not line) 0 (status-of-line line)))

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
(define (read-headers reader)
  (let loop ([out '()])
    (define line (reader-line reader))
    (cond
      [(not line) (reverse out)]
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
      (chunked-line (http-stream-reader stream) (http-stream-buffer stream))
      (reader-line (http-stream-reader stream))))

;; chunked-line answers the next line of a chunked body, or NOTHING when
;; the body is done. The text of a chunk that has no line in it yet
;; waits in the buffer, and the next chunk is read when it is needed.
(define (chunked-line reader buffer)
  (let loop ()
    (define parts (first-line (unbox buffer)))
    (if (car parts)
        (begin (set-box! buffer (cdr parts)) (car parts))
        ;; the body is done when the last chunk was read: the stream
        ;; ends there, and the end is told and not waited for. A reader
        ;; that loops on the end spins forever and burns the battery.
        (if (fill-chunk! reader buffer)
            (loop)
            #f))))

;; first-line answers the first line of a text and the rest of it. The
;; line is NOTHING when the text holds no complete line yet: a chunk
;; can end in the middle of a line, and the rest of that line comes
;; with the next chunk. An empty line is a line, and it is not the same
;; thing as a line that is not there yet — confusing the two makes the
;; reader spin on an empty buffer and never read a byte.
(define (first-line text)
  (let loop ([i 0])
    (cond
      [(>= i (string-length text)) (cons #f #f)]
      [(char=? (string-ref text i) #\newline)
       (cons (substring text 0 i) (substring text (add1 i)))]
      [else (loop (add1 i))])))

;; fill-chunk! reads one chunk of a chunked body and puts its text in the
;; buffer. The size line names how many bytes the chunk holds, and the
;; blank line after the chunk ends it.
(define (fill-chunk! reader buffer)
  (define size-line (reader-line reader))
  (cond
    [(not size-line) (set-box! buffer "") #f]
    [(string=? (string-trim size-line) "") (fill-chunk! reader buffer)]
    [else
     (define size (chunk-size size-line))
     (cond
       [(not size) (set-box! buffer "") #f]
       [(= size 0) (set-box! buffer "") #f]
       [else
        (define chunk (reader-bytes reader size))
        (reader-line reader)
        (set-box! buffer (string-append (unbox buffer) chunk))
        #t])]))

;; read-body reads the body of a reply. A chunked body is read chunk by
;; chunk, because that is how the server sends it when the length is
;; not known in advance; any other body is read to its length, or to
;; the end when the reply names no length.
(define (read-body reader headers)
  (define encoding (header-value headers "transfer-encoding"))
  (cond
    [(and encoding (string-contains? (string-downcase encoding) "chunked"))
     (read-chunks reader)]
    [else
     (define length
       (string->number (or (header-value headers "content-length") "0")))
     (if (> length 0)
         (reader-bytes reader length)
         (reader-rest reader))]))

;; read-chunks reads a chunked body and answers the text of it.
(define (read-chunks reader)
  (let loop ([out ""])
    (define line (reader-line reader))
    (cond
      [(or (not line) (string=? (string-trim line) "")) out]
      [else
       (define size (chunk-size line))
       (define chunk (if (> size 0) (reader-bytes reader size) ""))
       (reader-line reader)
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
