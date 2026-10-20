#lang racket/base
;; One job: the send check — the send really delivers, and the turn
;; really ends. Registered in plan/package-tree.org; lands with TODO
;; item 14.
;;
;; The agent is a stub the stage writes itself: a server on the loopback
;; that speaks the agent's wire — a session, a prompt, and a chunked
;; event feed — and answers with one piece of text and the end of the
;; turn. No model, no account, no service: the proof is the wire, and
;; the wire is the part that hung.
;;
;; The proofs, one by one, and each one is real:
;;   1. the session opens
;;   2. the event feed opens
;;   3. the bundle is delivered
;;   4. the region travels: the agent receives the region's own text
;;   5. the turn ends: the agent's text comes back and the read stops
;;
;; The exit code is the answer: 0 when the proofs hold, 3 when one of
;; them does not.

(require json
         racket/async-channel
         racket/bytes
         racket/list
         racket/port
         racket/string
         racket/tcp
         "../editor/src/buffer/selection.rkt"
         "../editor/src/send/bundle.rkt"
         "../editor/src/send/opencode-adapter.rkt")

;; session-id is the session the stub hands out: one session, one turn.
(define session-id "ses_gate")

;; agent-text is what the stub says in its answer: the proof is that
;; this text comes back, and it comes back because the turn ended.
(define agent-text "the gate agent answers")

;; region-body is the text the human marked in the buffer: the region
;; travels as this text, and the stub says whether it arrived.
(define region-body "the region the human marked")

;; delivered holds the body the stub received in the prompt.
(define delivered (box ""))

;; bundle-arrived is posted when the bundle reaches the stub. The feed
;; waits on it: the feed is open BEFORE the bundle goes out, and the
;; events are about that bundle's turn.
(define bundle-arrived (make-channel))

;; json-text answers the JSON text of a value: the stub's body, and the
;; event it writes.
(define (json-text value)
  (call-with-output-string (lambda (port) (write-json value port))))

;; byte-count answers how many bytes a text is on the wire: the chunk
;; sizes the feed writes must count bytes, not characters.
(define (byte-count text)
  (bytes-length (string->bytes/utf-8 text)))

;; stub-reader reads the bytes of a request: the request line, the
;; headers and the body come from ONE reader, so no byte is read twice
;; and no byte is left in a buffer nobody looks at. The bytes are read
;; as bytes, so no decoder can hold half a character of the body.
(struct stub-reader (port buffer) #:transparent #:mutable)

;; reader-refill! takes ONE byte off the socket into the reader's
;; buffer, and answers whether one came.
(define (reader-refill! reader)
  (define more (read-bytes 1 (stub-reader-port reader)))
  (if (eof-object? more)
      #f
      (begin
        (set-stub-reader-buffer! reader (bytes-append (stub-reader-buffer reader) more))
        #t)))

;; reader-line answers the next line of the request, without the newline
;; and without the carriage return before it, or NOTHING when the
;; request is done.
(define (reader-line reader)
  (let loop ()
    (define buffer (stub-reader-buffer reader))
    (define index (index-of-byte buffer (char->integer #\newline)))
    (if index
        (let ([line (bytes->string/utf-8 (subbytes buffer 0 index))])
          (set-stub-reader-buffer! reader (subbytes buffer (add1 index) (bytes-length buffer)))
          (drop-carriage-return line))
        (if (reader-refill! reader)
            (loop)
            (let ([rest (stub-reader-buffer reader)])
              (set-stub-reader-buffer! reader #"")
              (if (zero? (bytes-length rest)) #f (bytes->string/utf-8 rest)))))))

;; reader-bytes answers exactly size bytes of the request.
(define (reader-bytes reader size)
  (let loop ([out #""])
    (define have (bytes-length out))
    (cond
      [(>= have size) (bytes->string/utf-8 (subbytes out 0 size))]
      [else
       (define buffer (stub-reader-buffer reader))
       (define take (min (- size have) (bytes-length buffer)))
       (set-stub-reader-buffer! reader (subbytes buffer take (bytes-length buffer)))
       (if (and (= take 0) (not (reader-refill! reader)))
           (bytes->string/utf-8 out)
           (loop (bytes-append out (subbytes buffer 0 take))))])))

;; index-of-byte answers where a byte is in a buffer, or NOTHING when
;; the buffer holds no such byte.
(define (index-of-byte buffer byte)
  (let loop ([i 0])
    (cond
      [(>= i (bytes-length buffer)) #f]
      [(= (bytes-ref buffer i) byte) i]
      [else (loop (add1 i))])))

;; drop-carriage-return answers a line without the carriage return
;; that ends it.
(define (drop-carriage-return line)
  (define size (string-length line))
  (if (and (> size 0) (char=? (string-ref line (sub1 size)) #\return))
      (substring line 0 (sub1 size))
      line))

;; open-stub opens the stub's door on the loopback and answers the
;; listener and the port it got. The port is the one the kernel hands
;; out, so two gate runs never fight over one.
(define (open-stub)
  (define listener (tcp-listen 0 4))
  (thread (lambda () (accept-loop listener)))
  (values listener (stub-port listener)))

;; stub-port answers the port the kernel gave the stub's door: the
;; listener was asked for port 0, so the port is whatever was free.
(define (stub-port listener)
  (call-with-values (lambda () (tcp-addresses listener #t))
    (lambda values (list-ref values 1))))

;; accept-loop takes every connection the stub is offered and serves it
;; in its own thread: the feed is a connection that stays open, and it
;; must not block the calls that come after it.
(define (accept-loop listener)
  (let loop ()
    (define-values (in out)
      (with-handlers ([exn:fail? (lambda (why) (values #f #f))])
        (tcp-accept listener)))
    (when (and in out)
      (thread (lambda ()
                (with-handlers ([exn:fail? (lambda (why)
                                            (fprintf (current-error-port) "the stub failed: ~a\n" (exn-message why)))])
                  (serve-connection in out))))
      (loop))))

;; serve-connection answers one call: the session, the prompt, or the
;; feed. The path decides which, and the stub answers nothing else.
(define (serve-connection in out)
  (define reader (stub-reader in #""))
  (define request (reader-line reader))
  (define path (request-path request))
  (define headers (read-headers reader))
  (define body (read-body reader headers))
  (cond
    [(equal? path "/api/session")
     (write-json-reply in out (hasheq 'data (hasheq 'id session-id)))]
    [(string-suffix? path "/prompt")
     (set-box! delivered (prompt-text body))
     (channel-put bundle-arrived #t)
     (write-json-reply in out (hasheq 'data (hasheq 'id "msg_gate")))]
    [(equal? path "/api/event")
     (serve-feed out)]
    [else
     (write-json-reply in out (hasheq 'data (hasheq)))]))

;; request-path answers the path of a request line.
(define (request-path request)
  (if (string? request)
      (let ([parts (string-split request " ")])
        (if (>= (length parts) 2) (cadr parts) ""))
      ""))

;; read-headers reads the header block of a request and answers the
;; name/value pairs.
(define (read-headers reader)
  (let loop ([out '()])
    (define line (reader-line reader))
    (cond
      [(not line) (reverse out)]
      [(string=? (string-trim line) "") (reverse out)]
      [else
       (define parts (string-split line ":"))
       (loop (if (>= (length parts) 2)
                 (cons (cons (string-trim (car parts))
                              (string-trim (string-join (cdr parts) ":")))
                       out)
                 out))])))

;; read-body reads the body of a request: the length the headers name.
(define (read-body reader headers)
  (define length
    (for/first ([header (in-list headers)]
                #:when (string=? (string-downcase (car header)) "content-length"))
      (string->number (cdr header))))
  (if (and length (> length 0))
      (reader-bytes reader length)
      ""))

;; prompt-text answers the text the prompt carried.
(define (prompt-text body)
  (with-handlers ([exn:fail? (lambda (why) "")])
    (define parsed (read-json (open-input-string body)))
    (hash-ref parsed 'text "")))

;; write-json-reply answers one call with JSON and closes the call: both
;; ends of the connection go, so the caller knows the body is done.
(define (write-json-reply in out value)
  (define body (json-text value))
  (fprintf out
           "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ~a\r\nconnection: close\r\n\r\n"
           (byte-count body))
  (display body out)
  (flush-output out)
  (close-input-port in)
  (close-output-port out))

;; serve-feed answers the event feed: a chunked stream that carries the
;; agent's text and then the end of the turn. The events come after the
;; bundle: the feed was open before the bundle went out.
(define (serve-feed out)
  (fprintf out
           "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\nconnection: keep-alive\r\n\r\n")
  (flush-output out)
  (channel-get bundle-arrived)
  (write-event out (hasheq 'type "session.text.delta"
                           'data (hasheq 'sessionID session-id 'delta agent-text)))
  (write-event out (hasheq 'type "session.execution.succeeded"
                           'data (hasheq 'sessionID session-id)))
  ;; the last chunk says the body is done
  (fprintf out "0\r\n\r\n")
  (flush-output out))

;; write-event writes one event of the feed as one chunk: the size, the
;; text, and the end of the chunk.
(define (write-event out event)
  (define text (string-append "data: " (json-text event) "\n\n"))
  (fprintf out "~x\r\n" (byte-count text))
  (display text out)
  (fprintf out "\r\n")
  (flush-output out))

;; client-for answers the client of the stub: the address is the
;; loopback and the port the kernel handed out, and nothing else about
;; the agent is needed.
(define (client-for port)
  (putenv "AIU_AGENT_URL" (format "http://127.0.0.1:~a" port))
  (putenv "AIU_AGENT_PASSWORD" "the gate's own password")
  (client-from-environment))

;; the-region answers the region the human marked: it runs from one
;; place to another, and the text of it is what the hot path holds.
(define the-region (region-from 10 25))

;; the-selection answers the selection part of the bundle: the region's
;; own text, as the hot path would hand it over.
(define the-selection
  (hash 'text (region-text (lambda (operation arguments) region-body) the-region)
        'from (region-anchor the-region)
        'to (region-point the-region)))

;; the-bundle answers the bundle the send carries: the region, the
;; file, the why. The why is never empty, or the bundle is refused.
(define the-bundle
  (make-bundle "aiu-editor" "aiu-ecosystem" "opencode"
               the-selection
               "/tmp/aiu-editor-gate/proof.txt"
               (hash 'line 1)
               #f
               "the gate proves that the region travels"))

;; run-proofs does the whole send against the stub and answers what
;; happened: the handle, the feed, the message, the events and the
;; text the agent said.
(define (run-proofs)
  (define-values (listener port) (open-stub))
  (define client (client-for port))
  (define-values (handle refusal) (client-open client))
  (define feed (client-open-feed client))
  (define-values (message refused) (client-deliver client handle (bundle-text the-bundle)))
  (define-values (events text refused2) (client-turn feed handle))
  (tcp-close listener)
  (list handle feed message refusal refused2 events text (unbox delivered)))

;; The check, for the gate.
(define (main)
  (define results (run-proofs))
  (define handle (car results))
  (define feed (cadr results))
  (define message (caddr results))
  (define refused (cadddr results))
  (define refused2 (list-ref results 4))
  (define events (list-ref results 5))
  (define text (list-ref results 6))
  (define arrived (list-ref results 7))
  (define proofs
    (list (list "the session opens" (and handle (not refused)))
          (list "the event feed opens" (and feed (not refused2)))
          (list "the bundle is delivered" (and message (not refused)))
          (list "the region travels" (string-contains? arrived region-body))
          (list "the turn ends with the agent's text" (string=? text agent-text))
          (list "the end of the turn is an event"
                (member "session.execution.succeeded"
                        (map (lambda (event) (hash-ref event 'type "")) events)))))
  (define failed (filter (lambda (pair) (not (cadr pair))) proofs))
  (if (null? failed)
      (begin
        (displayln (format "OK send-check — the send holds: ~a" (string-join (map car proofs) "; ")))
        (exit 0))
      (begin
        (displayln (format "BAD send-check — the proof that failed: ~a" (string-join (map car failed) "; ")))
        (exit 3))))

(module+ main
  (main))
