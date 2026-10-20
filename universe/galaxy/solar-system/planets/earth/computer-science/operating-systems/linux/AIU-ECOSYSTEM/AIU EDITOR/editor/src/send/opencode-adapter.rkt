#lang racket/base
;; One job: the OpenCode client — the agent's own API in the agent's own
;; words. It is the ONE file that knows what OpenCode is; everything
;; else in this program knows only the boundary.
;;
;; The seam is OpenCode's headless server on the loopback (D-009): the
;; contract's recommendation, and the one that needs no account and no
;; service. The server prints its own password when it starts, so the
;; address and the password are facts about this run and come from the
;; environment. There is no config file to load at startup (rule 03).
;;
;; The session the editor opens asks for every mutating action: the
;; agent's writes come back as permission asks, and the human answers
;; them. The editor never answers one for the human (rule 07).
;;
;; Registered in plan/package-tree.org; lands with TODO item 9.

(require json
         net/base64
         racket/bytes
         racket/list
         racket/port
         racket/string
         "../machine/http.rkt")

;; opencode-client is the client of the OpenCode server: the base URL,
;; the user, the password and the directory the work is about.
(struct opencode-client (base-url user password directory) #:transparent)

;; default-url is where the OpenCode server listens when nothing else
;; says otherwise: the loopback, never a public address.
(define default-url "http://127.0.0.1:4096")

;; client-from-environment answers the client of the server this run
;; talks to. The address, the user and the password come from the
;; environment: AIU_AGENT_URL, AIU_AGENT_USER, AIU_AGENT_PASSWORD and
;; AIU_AGENT_DIRECTORY. A missing password is a missing fact, and the
;; server refuses the call by name rather than the client guessing.
(define (client-from-environment)
  (opencode-client (env-text "AIU_AGENT_URL" default-url)
                   (env-text "AIU_AGENT_USER" "opencode")
                   (env-text "AIU_AGENT_PASSWORD" "")
                   (env-text "AIU_AGENT_DIRECTORY" ".")))

;; env-text answers the value of an environment variable, or the given
;; text when the variable is not set or is empty.
(define (env-text name fallback)
  (define value (getenv name))
  (if (and value (not (string=? value ""))) value fallback))

;; client-name answers the name of the agent this client reaches.
(define (client-name client)
  "opencode")

;; client-headers answers the headers every call carries: the host, the
;; authorization and the directory the work is about.
(define (client-headers client)
  (list (cons "Host" (url-host-part (opencode-client-base-url client)))
        (cons "Authorization" (basic-authorization (opencode-client-user client)
                                                 (opencode-client-password client)))
        (cons "Content-Type" "application/json")
        (cons "X-Opencode-Directory" (opencode-client-directory client))))

;; url-host-part answers the host of a base URL, without the port.
(define (url-host-part base-url)
  (define without-scheme (string-replace base-url #rx"^[a-z]+://" ""))
  (car (string-split without-scheme ":")))

;; basic-authorization answers the authorization header of a user and a
;; password: the two names joined by a colon, in base64.
(define (basic-authorization user password)
  (define encoded (bytes->string/utf-8 (base64-encode (string->bytes/utf-8 (string-append user ":" password)))))
  (string-append "Basic " (string-replace encoded "\r\n" "")))

;; client-version answers the version of the agent the server runs. It
;; is asked of the server, so the pin is the version that is really
;; there and not the one this file remembers.
(define (client-version client)
  (define reply (call client "GET" "/api/info" #f))
  (if reply
      (let ([parsed (json-of (http-reply-body reply))])
        (if (hash? parsed) (hash-ref parsed 'version "unverified") "unverified"))
      "unverified"))

;; call makes one call to the server and answers the reply, or nothing
;; when the server cannot be reached. The body is JSON, or nothing for
;; a call that carries none.
(define (call client method path body)
  (http-call (opencode-client-base-url client)
             method
             path
             (client-headers client)
             (if body (json-text body) "")))

;; json-text answers the JSON text of a value: the body of a call is
;; JSON, and it is a string the client sends, never a print.
(define (json-text value)
  (call-with-output-string (lambda (port) (write-json value port))))

;; json-of answers the JSON of a text, or nothing when the text is not
;; JSON. A body the server did not send as JSON is a failure of the
;; server, and the caller says so instead of guessing.
(define (json-of text)
  (with-handlers ([exn:fail? (lambda (why) #f)])
    (read-json (open-input-string text))))

;; client-open opens a session with the agent and answers the session
;; handle, or the refusal by name. Every mutating action asks: the
;; agent's writes come back as permission asks, and the human answers
;; them.
(define (client-open client)
  (define reply
    (call client "POST" "/api/session"
                 (hasheq 'title "the aiu editor"
                         'permissions (list (hasheq 'action "edit" 'resource "*" 'effect "ask")
                                            (hasheq 'action "bash" 'resource "*" 'effect "ask")
                                            (hasheq 'action "webfetch" 'resource "*" 'effect "ask")))))
  (if (and reply (<= 200 (http-reply-status reply) 299))
      (let ([parsed (json-of (http-reply-body reply))])
        (define data (if (hash? parsed) (hash-ref parsed 'data #f) #f))
        (define id (if (hash? data) (hash-ref data 'id #f) #f))
        (if id
            (values id #f)
            (values #f (client-refusal "the server did not answer with a session"))))
      (values #f (client-refusal "the agent is not reachable: the server refused the call"))))

;; client-deliver hands the bundle's text to the agent and answers the
;; message it made, or the refusal by name.
(define (client-deliver client session-id text)
  (define reply (call client "POST" (session-path session-id "/prompt") (hasheq 'text text)))
  (if (and reply (<= 200 (http-reply-status reply) 299))
      (let ([parsed (json-of (http-reply-body reply))])
        (if (hash? parsed)
            (values (hash-ref parsed 'data #f) #f)
            (values #f (client-refusal "the server did not answer with a message"))))
      (values #f (client-refusal "the agent refused the bundle"))))

;; client-open-feed opens the agent's event feed and answers the stream,
;; or nothing when the feed cannot be opened. The feed is opened BEFORE
;; the bundle goes out: an event that came before the feed was open is
;; an event nobody saw.
(define (client-open-feed client)
  (http-open-stream (opencode-client-base-url client)
                    "GET"
                    "/api/event"
                    (client-headers client)))

;; client-turn reads the agent's events until the turn ends or the agent
;; asks for a permission, and answers the events, the text the agent
;; said, and the refusal. There is NO TIMER: the read waits for the
;; next line of the feed, and the feed is what ends the wait.
(define (client-turn stream session-id)
  (if (not stream)
      (values #f #f (client-refusal "the agent is not reachable: the event feed did not open"))
      (let loop ([events '()] [text ""])
        (define line (http-stream-line stream))
        (cond
          [(eof-object? line)
           (close-input-port (http-stream-port stream))
           (values (reverse events) text #f)]
          [else
           (define event (event-of-line line))
           (cond
             [(not event) (loop events text)]
             [(not (event-of-session? event session-id)) (loop events text)]
             [else
              (define type (hash-ref event 'type ""))
              (cond
                [(string=? type "session.text.delta")
                 (loop (cons event events)
                       (string-append text (hash-ref (hash-ref event 'data #f) 'delta "")))]
                [(string=? type "permission.asked")
                 (close-input-port (http-stream-port stream))
                 (values (reverse (cons event events)) text #f)]
                [(or (string=? type "session.execution.succeeded")
                     (string=? type "session.execution.failed"))
                 (close-input-port (http-stream-port stream))
                 (values (reverse (cons event events)) text #f)]
                [else (loop (cons event events) text)])])]))))

;; event-of-line answers the event of one line of the feed, or nothing
;; when the line carries none: the feed sends blank lines and notes
;; between the events.
(define (event-of-line line)
  (if (string-prefix? (string-trim line) "data:")
      (with-handlers ([exn:fail? (lambda (why) #f)])
        (json-of (string-trim (substring line 5))))
      #f))

;; event-of-session? answers whether an event belongs to a session.
(define (event-of-session? event session-id)
  (or (equal? (hash-ref (hash-ref event 'data #f) 'sessionID #f) session-id)
      (equal? (hash-ref event 'sessionID #f) session-id)))

;; client-permissions answers the permission asks the agent is waiting
;; for: each one names the action, the files it touches and the id the
;; human answers it by.
(define (client-permissions client session-id)
  (define reply (call client "GET" (session-path session-id "/permission") #f))
  (if (and reply (<= 200 (http-reply-status reply) 299))
      (let ([parsed (json-of (http-reply-body reply))])
        (if (hash? parsed) (hash-ref parsed 'data '()) '()))
      '()))

;; ask-files answers the files one permission ask touches: the resources
;; it names and the files in its own metadata.
(define (ask-files ask)
  (define resources (hash-ref ask 'resources '()))
  (define files (hash-ref (hash-ref ask 'metadata #f) 'files '()))
  (append resources
          (for/list ([file (in-list files)])
            (hash-ref file 'file ""))))

;; client-reply answers one permission ask, the way the human said:
;; once, always or reject. The decision is never inferred.
(define (client-reply client session-id request-id decision)
  (define reply (call client "POST"
                            (session-path session-id (string-append "/permission/" request-id "/reply"))
                            (hasheq 'decision decision)))
  (if (and reply (<= 200 (http-reply-status reply) 299))
      (values #t #f)
      (values #f (client-refusal "the agent refused the answer to the permission ask"))))

;; client-cancel cancels the turn the agent is in.
(define (client-cancel client session-id)
  (define reply (call client "POST" (session-path session-id "/interrupt") #f))
  (if (and reply (<= 200 (http-reply-status reply) 299))
      (values #t #f)
      (values #f (client-refusal "the agent could not be cancelled"))))

;; client-end ends the session.
(define (client-end client session-id)
  (define reply (call client "DELETE" (session-path session-id "") #f))
  (if (and reply (<= 200 (http-reply-status reply) 299))
      (values #t #f)
      (values #f (client-refusal "the session could not be ended"))))

;; session-path answers the path of a call inside a session.
(define (session-path session-id suffix)
  (string-append "/api/session/" session-id suffix))

;; client-refusal answers the refusal of the client: what it cannot do,
;; and what to do about it. A refusal names the agent and the reason.
(define (client-refusal what)
  (hash 'kind "err-no-agent"
        'who "opencode"
        'what what
        'what_to_do "start the agent's server on the loopback, or set AIU_AGENT_URL and AIU_AGENT_PASSWORD"))

;; The client, for the boundary above it.
(provide opencode-client
         opencode-client-base-url
         opencode-client-user
         opencode-client-password
         opencode-client-directory
         client-from-environment
         client-name
         client-version
         client-headers
         client-open
         client-deliver
         client-open-feed
         client-turn
         client-permissions
         ask-files
         client-reply
         client-cancel
         client-end
         client-refusal)
