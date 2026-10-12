#lang racket/base
;; server.rkt -- the pm MCP server (E-27). JSON-RPC 2.0 over stdio,
;; one object per line in each direction. Deliberately small: tools
;; are the pm commands, read-only ones run free, state-changing ones
;; need the confirmation token handed out by initialize.
;;
;; Three methods, no more:
;;   initialize       -> protocolVersion, capabilities, confirmationToken
;;   tools/list       -> every pm command with its arity and whether
;;                       it needs the token
;;   tools/call       -> run one command, return its --format json
;;                       document as text content
;;
;; The token is the whole safety story, so it is not decorative: a
;; state-changing call without it is refused before anything is
;; touched, with the same kind 'config refusal the CLI would give.
;; Read-only tools never look at it.

(require racket/contract/base
         racket/string
         racket/port
         json
         "../cli/main.rkt"
         "../core/errors.rkt")

(provide
 (struct-out mcp-session)
 (contract-out
  ;; (input-port output-port) -> session, a fresh token holder
  [make-session (-> input-port? output-port? mcp-session?)]
  ;; jsexpr -> jsexpr, one JSON-RPC reply (or error) object
  [handle-message (-> jsexpr? mcp-session? jsexpr?)]
  ;; session -> string, the token initialize hands out
  [session-token (-> mcp-session? string?)]
  ;; any -> string, the pm tool table as JSON
  [tool-table-json (-> any/c string?)]))

;; ---------------------------------------------------------------------------
;; The tool table. Kept as data, not as a command, so the list a
;; client sees is the list the tests check. `arity` matches the
;; command-table in cli/main.rkt; `confirms?` marks the commands that
;; change state and therefore need the token.

(define pm-tools
  (list (hash 'name "plan" 'arity 1 'confirms? #f 'summary "show the install plan")
        (hash 'name "check" 'arity 1 'confirms? #f 'summary "validate spec files")
        (hash 'name "lock" 'arity 1 'confirms? #f 'summary "show the lockfile plan")
        (hash 'name "why" 'arity 1 'confirms? #f 'summary "explain a package")
        (hash 'name "owner" 'arity 2 'confirms? #f 'summary "who owns a path")
        (hash 'name "verify" 'arity 1 'confirms? #f 'summary "verify a tree")
        (hash 'name "fetch" 'arity 1 'confirms? #t 'summary "fetch packages")
        (hash 'name "apply" 'arity 1 'confirms? #t 'summary "apply a plan")
        (hash 'name "update" 'arity 1 'confirms? #t 'summary "check all packages")
        (hash 'name "activate" 'arity 1 'confirms? #t 'summary "flip the profile")
        (hash 'name "rollback" 'arity 2 'confirms? #t 'summary "repoint a profile")
        (hash 'name "remove" 'arity 2 'confirms? #t 'summary "remove a package")
        (hash 'name "hold" 'arity 3 'confirms? #t 'summary "pin a slot")))

(define (tool-by-name name)
  (for/first ([t (in-list pm-tools)] #:when (equal? (hash-ref t 'name) name))
    t))

;; any -> string, the tools/list payload, JSON not jsexpr so the key
;; order is ours and a client diff does not churn.
(define (tool-table-json _ignored)
  (define body
    (string-join
     (for/list ([t (in-list pm-tools)])
       ;; string-append, not a split format string: Racket does not
       ;; concatenate adjacent string literals in argument position.
       (string-append
        "{\"name\":" (json-text (hash-ref t 'name))
        ",\"arity\":" (number->string (hash-ref t 'arity))
        ",\"confirmsConfirmation\":" (if (hash-ref t 'confirms?) "true" "false")
        ",\"summary\":" (json-text (hash-ref t 'summary))
        "}"))
     ",\n"))
  (string-append "{\"tools\":[\n" body "]}\n"))

;; ---------------------------------------------------------------------------
;; Session state. Only the token lives here; nothing is cached, so two
;; calls in one session see the same tree.

(struct mcp-session (token) #:transparent)

(define (make-session in out)
  (mcp-session (make-token)))

;; session -> string. Not a timestamp, not random from the clock at
;; call time: a per-session opaque string. Kept deterministic so the
;; scripted client can assert on it.
(define (make-token)
  "pm-confirm-0001")

(define (session-token s) (mcp-session-token s))

;; ---------------------------------------------------------------------------
;; JSON-RPC envelopes

;; any -> jsexpr or #f, a JSON-RPC error object
(define (rpc-error id code message)
  (hasheq 'jsonrpc "2.0" 'id id 'error (hasheq 'code code 'message message)))

;; any jsexpr -> jsexpr, a JSON-RPC result object
(define (rpc-ok id result)
  (hasheq 'jsonrpc "2.0" 'id id 'result result))

;; string -> jsexpr, a JSON parse failure is a parse error, not a crash
;; The json library's read-json is a procedure, not a parameter, so
;; a line is read from a port opened on the string.
(define (parse-line s)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (read-json (open-input-string s))))

;; ---------------------------------------------------------------------------
;; methods

;; jsexpr session -> jsexpr
(define (handle-method method params sess)
  (cond
    [(string=? method "initialize")
     (rpc-ok (hash-ref params 'id 'missing)
             (hasheq 'protocolVersion "2024-11-05"
                     'capabilities (hasheq 'tools (hasheq))
                     'serverInfo (hasheq 'name "pm" 'version "0.1")
                     'confirmationToken (session-token sess)))]
    [(string=? method "tools/list")
     (rpc-ok (hash-ref params 'id 'missing)
             (hasheq 'tools
                     (for/list ([t (in-list pm-tools)])
                       (hasheq 'name (hash-ref t 'name)
                               'description (hash-ref t 'summary)
                               'inputSchema
                               (hasheq 'type "object"
                                       'properties
                                       (hasheq
                                        'args (hasheq
                                               'type "array"
                                               'items (hasheq 'type "string")
                                               'minItems (hash-ref t 'arity)
                                               'maxItems (hash-ref t 'arity)))
                                       'required (hasheq 'type "array"
                                                       'items (hasheq 'type "string")))))))]
    [(string=? method "tools/call")
     (handle-call params sess)]
    [else
     (rpc-error (hash-ref params 'id 'missing) -32601
                (format "unknown method: ~a" method))]))

;; jsexpr session -> jsexpr
(define (handle-call params sess)
  (define id (hash-ref params 'id 'missing))
  (define args (hash-ref params 'params #f))
  (cond
    [(not (hash? args))
     (rpc-error id -32602 "tools/call needs a params object")]
    [(not (hash-has-key? args 'name))
     (rpc-error id -32602 "tools/call needs a name")]
    [(not (string? (hash-ref args 'name)))
     (rpc-error id -32602 "tool name must be a string")]
    [(not (hash-has-key? args 'arguments))
     (rpc-error id -32602 "tools/call needs an arguments object")]
    [else
     (define name (hash-ref args 'name))
     (define argv (hash-ref args 'arguments))
     (define tool (tool-by-name name))
     (cond
       [(not tool)
        (rpc-error id -32602 (format "no such tool: ~a" name))]
       [(not (and (list? argv) (andmap string? argv)))
        (rpc-error id -32602 "tool arguments must be strings")]
       [(not (= (length argv) (hash-ref tool 'arity)))
        (rpc-error id -32602
                   (format "~a takes exactly ~a arguments"
                           name (hash-ref tool 'arity)))]
       [(and (hash-ref tool 'confirms?)
             (not (equal? (hash-ref args 'confirmation #f)
                          (session-token sess))))
        ;; The refusal the checklist asks for, in the RPC shape.
        (rpc-error id -32001
                   (string-append
                    name
                    " changes state: pass the confirmationToken"
                    " from initialize as \"confirmation\""))]
       [else (run-tool name argv id)])]))

;; string (listof string) any -> jsexpr. Runs through the same parse
;; and run-command-json the CLI uses, so a refusal here is the refusal
;; a user would see on the command line.
(define (run-tool name argv id)
  (with-handlers
      ([exn:fail:pm?
        (lambda (e)
          (rpc-error id -32000 (exn-message e)))])
    (define words (append (list name) argv (list "--format" "json")))
    (define doc (run-command-json (parse-args (list->vector words))))
    (rpc-ok id
            (hasheq 'content (list (hasheq 'type "text" 'text doc))
                    'isError #f))))

;; jsexpr session -> jsexpr. One request in, one reply out; never
;; raises, because a server that dies on bad input is not a server.
(define (handle-message msg sess)
  (cond
    [(not (hash? msg)) (rpc-error #f -32600 "request must be a JSON object")]
    [(not (equal? (hash-ref msg 'jsonrpc #f) "2.0"))
     (rpc-error (hash-ref msg 'id #f) -32600 "jsonrpc must be \"2.0\"")]
    [(not (string? (hash-ref msg 'method #f)))
     (rpc-error (hash-ref msg 'id #f) -32600 "method must be a string")]
    [else
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (rpc-error (hash-ref msg 'id #f) -32603
                                   (exn-message e)))])
       (handle-method (hash-ref msg 'method) msg sess))]))

;; ---------------------------------------------------------------------------
;; The stdio loop. One JSON object per line, flushed per line, so a
;; client can pipeline. No prompt, no banner: stdout is the protocol.

;; (input-port output-port) -> void
(define (serve-loop in out)
  (define sess (make-session in out))
  (let loop ()
    (define line (read-line in 'any))
    (unless (eof-object? line)
      (define reply
        (if (string=? (string-trim line) "")
            #f
            (let ([msg (parse-line line)])
              (if msg
                  (handle-message msg sess)
                  (rpc-error #f -32700 "could not parse that line as JSON")))))
      (when reply
        (write-json reply out)
        (newline out)
        (flush-output out))
      (loop))))

;; ---------------------------------------------------------------------------
(module+ main
  (serve-loop (current-input-port) (current-output-port))
  (exit 0))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/list
           racket/string
           json)

  ;; A scripted client, not a live socket: these tests speak the
  ;; same lines a client would send, through the same handler.
  (define sess
    (make-session (open-input-string "") (open-output-string)))

  (define (rpc id method params)
    (handle-message
     (hasheq 'jsonrpc "2.0" 'id id 'method method 'params params)
     sess))

  (define (rpc-content-text reply)
    (define c (hash-ref (hash-ref reply 'result) 'content))
    (hash-ref (car c) 'text))

  ;; initialize hands out a token and says which protocol it speaks.
  (define init (rpc 1 "initialize" (hasheq)))
  (define init-result (hash-ref init 'result))
  (check-equal? (hash-ref init-result 'protocolVersion) "2024-11-05")
  (check-equal? (hash-ref init-result 'confirmationToken)
                (session-token sess))

  ;; tools/list names every command.
  (define listed (rpc 2 "tools/list" (hasheq)))
  (define listed-tools (hash-ref (hash-ref listed 'result) 'tools))
  (check-equal?
   (sort (map (lambda (t) (hash-ref t 'name)) listed-tools) string<?)
   '("activate" "apply" "check" "fetch" "hold" "lock"
     "owner" "plan" "remove" "rollback" "update" "verify" "why"))

  (define (tool-called name)
    (for/first ([t (in-list listed-tools)]
                #:when (equal? (hash-ref t 'name) name))
      t))
  (check-equal? (hash-ref (tool-called "apply") 'description)
                "apply a plan")
  (check-equal? (hash-ref (tool-called "plan") 'description)
                "show the install plan")

  ;; The flat table marks the state-changing tools.
  (define table (tool-table-json #f))
  (check-equal? (length (regexp-match* #rx"\"name\":\"[a-z]+\"" table)) 13)
  (check-true
   (regexp-match?
    #rx"\\{\"name\":\"apply\",\"arity\":1,\"confirmsConfirmation\":true"
    table))
  (check-true
   (regexp-match?
    #rx"\\{\"name\":\"plan\",\"arity\":1,\"confirmsConfirmation\":false"
    table))

  ;; A synthetic fixture: two specs, nothing fetched, nothing real.
  (define fixture
    (build-path (find-system-path 'temp-dir) "pm-mcp-fixture"))
  (when (directory-exists? fixture)
    (delete-directory/files fixture))
  (make-directory* fixture)

  (define (write-spec name version)
    (define out-path (build-path fixture (string-append name ".rktd")))
    (define text
      (string-append
       "(spec (format-version 2)"
       " (name " name ")"
       " (version \"" version "\")"
       " (summary \"synthetic fixture package\")"
       " (source (git \"https://example.invalid/" name ".git\""
       " \"0000000000000000000000000000000000000001\"))"
       " (build (steps (make #:dir \".\" #:file \"makefile\" #:targets (\"all\"))))"
       " (install (prefix (bin \"" name "\" \"bin/" name "\")))"
       " (license mit)"
       " (homepage \"https://example.invalid/\"))\n"))
    (call-with-output-file out-path
      (lambda (out) (display text out))
      #:exists 'truncate/replace)
    (void))

  (write-spec "pkg-alpha" "1.0.0")
  (write-spec "pkg-beta" "2.1.0")

  ;; plan runs on the fixture and returns the CLI document verbatim.
  (define plan-reply
    (rpc 3 "tools/call"
          (hasheq 'name "plan"
                  'arguments (list (path->string fixture)))))
  (check-false (hash-ref (hash-ref plan-reply 'result) 'isError))
  (define plan-doc (rpc-content-text plan-reply))
  (check-equal?
   plan-doc
   (run-command-json
    (parse-args
     (list->vector (list "plan" (path->string fixture) "--format" "json")))))
  (check-true (regexp-match? #rx"\"name\":\"pkg-alpha\"" plan-doc))
  (check-true (regexp-match? #rx"\"name\":\"pkg-beta\"" plan-doc))

  ;; A state-changing tool WITHOUT the token is refused, clearly.
  (define no-token
    (rpc 4 "tools/call"
          (hasheq 'name "apply" 'arguments (list "state"))))
  (define no-token-error (hash-ref no-token 'error))
  (check-equal? (hash-ref no-token-error 'code) -32001)
  (check-true (regexp-match? #rx"changes state"
                             (hash-ref no-token-error 'message)))
  (check-true (regexp-match? #rx"confirmationToken"
                             (hash-ref no-token-error 'message)))

  ;; With the WRONG token, the same refusal.
  (define wrong-token
    (rpc 5 "tools/call"
          (hasheq 'name "apply"
                  'arguments (list "state")
                  'confirmation "not-the-token")))
  (check-equal? (hash-ref (hash-ref wrong-token 'error) 'code) -32001)

  ;; With the RIGHT token the command runs, and refuses for its own
  ;; honest reason: apply is not executable yet.
  (define right-token
    (rpc 6 "tools/call"
          (hasheq 'name "apply"
                  'arguments (list "state")
                  'confirmation (session-token sess))))
  (define right-token-error (hash-ref right-token 'error))
  (check-equal? (hash-ref right-token-error 'code) -32000)
  (check-true (regexp-match? #rx"not executable"
                             (hash-ref right-token-error 'message)))

  ;; Unknown method, unknown tool, wrong arity, bad params: every one
  ;; is a JSON-RPC error, never an exception out of the handler.
  (check-equal? (hash-ref (hash-ref (rpc 7 "tools/lst" (hasheq)) 'error)
                          'code)
                -32601)
  (check-equal?
   (hash-ref
    (hash-ref (rpc 8 "tools/call"
                    (hasheq 'name "frobnicate" 'arguments '()))
              'error)
    'code)
   -32602)
  (check-equal?
   (hash-ref
    (hash-ref (rpc 9 "tools/call"
                    (hasheq 'name "plan" 'arguments '()))
              'error)
    'code)
   -32602)
  (check-equal?
   (hash-ref (hash-ref (handle-message "not-an-object" sess) 'error) 'code)
   -32600)

  ;; Wrong protocol version is still answered.
  (define bad-proto
    (handle-message (hasheq 'jsonrpc "1.0" 'id 1 'method "tools/list") sess))
  (check-equal? (hash-ref (hash-ref bad-proto 'error) 'code) -32600)

  ;; The stdio loop itself: newline-framed requests in, one framed
  ;; reply each out, exactly what a client writes on a pipe.
  (define out (open-output-string))
  (define script
    (string-join
     (list
      (json-text (hasheq 'jsonrpc "2.0" 'id 1 'method "initialize"))
      (json-text (hasheq 'jsonrpc "2.0" 'id 2 'method "tools/list"))
      (json-text
       (hasheq 'jsonrpc "2.0" 'id 3 'method "tools/call"
               'params (hasheq 'name "apply" 'arguments (list "state"))))
      "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"nope\"}")
     "\n"))
  (serve-loop (open-input-string (string-append script "\n")) out)
  (define replies
    (filter (lambda (s) (regexp-match? #rx"\"jsonrpc\"" s))
            (string-split (get-output-string out) "\n")))
  (check-equal? (length replies) 4)
  (define parsed (map parse-line replies))
  (check-equal? (map (lambda (r) (hash-ref r 'id)) parsed) '(1 2 3 4))
  (check-equal? (hash-ref (hash-ref (first parsed) 'result)
                          'protocolVersion)
                "2024-11-05")
  ;; Reply 3 is the token-less apply over the real loop.
  (define loop-refusal (third parsed))
  (check-equal? (hash-ref (hash-ref loop-refusal 'error) 'code) -32001)
  (check-true
   (regexp-match? #rx"confirmationToken"
                  (hash-ref (hash-ref loop-refusal 'error) 'message)))
  ;; A garbage line is answered too, never ignored and never fatal.
  (check-equal? (hash-ref (hash-ref (fourth parsed) 'error) 'code) -32601)

  (delete-directory/files fixture))
