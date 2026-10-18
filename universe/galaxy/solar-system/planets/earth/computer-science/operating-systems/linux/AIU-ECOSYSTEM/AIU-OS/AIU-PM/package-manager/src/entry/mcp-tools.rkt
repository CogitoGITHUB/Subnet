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
         racket/file
         racket/format
         racket/list
         racket/path
         racket/string
         racket/port
         openssl/sha1
         json
         "./cli.rkt"
         "../errors/error-type.rkt"
         "../narration/narration.rkt"
         "../security/security.rkt")

(provide
 (struct-out mcp-session)
 (contract-out
  ;; (input-port output-port) -> session, a fresh token holder
  [make-session (-> input-port? output-port? mcp-session?)]
  ;; jsexpr -> jsexpr, one JSON-RPC reply (or error) object
  [handle-message (-> jsexpr? mcp-session? jsexpr?)]
  ;; session -> string, the token initialize hands out
  [session-token (-> mcp-session? string?)]
  ;; The token request: bind this session's token to one plan. The human
  ;; approves outside this process, so this records the binding and
  ;; returns. A spent token refuses to be rebound.
  [session-authorise! (-> mcp-session? string? void?)]
  ;; session -> boolean, has this token already approved one call?
  [session-token-spent? (-> mcp-session? boolean?)]
  ;; session -> string or #f, the plan this token was issued for
  [session-plan-digest (-> mcp-session? (or/c string? #f))]
  ;; tool name + argv -> string, the digest a token is bound to
  [plan-digest (-> string? (listof string?) string?)]
  ;; the four refusals, for the gate and for the suite that checks it
  [confirmation-refusal-for (-> string? (listof string?) mcp-session?
                               jsexpr? (or/c string? #f))]
  ;; any -> string, the pm tool table as JSON
  [tool-table-json (-> any/c string?)]
  ;; Parameter, not an argument: the events dir is a seam and a test
  ;; must be able to point it at a temp root. Production never sets it.
  [current-feed-dir parameter?]))

;; ---------------------------------------------------------------------------
;; The tool table. Kept as data, not as a command, so the list a
;; client sees is the list the tests check. `arity` matches the
;; command-table in cli/main.rkt; `confirms?` marks the commands that
;; change state and therefore need the token.

(define pm-tools
  (list ;; --- the event feed (V-4). Read-only, and they read the SAME
        ;; JSON Lines the OpenCode plugin reads, not a second format.
        (hash 'name "events.runs" 'arity 0 'confirms? #f
              'summary "list run ids pm has a feed for")
        (hash 'name "events.tail" 'arity 2 'confirms? #f
              'summary "events after a seq: RUN-ID FROM-SEQ")
        (hash 'name "run.get" 'arity 1 'confirms? #f
              'summary "START/END summary of one run")
        (hash 'name "plan" 'arity 1 'confirms? #f 'summary "show the install plan")
        (hash 'name "check" 'arity 1 'confirms? #f 'summary "validate spec files")
        (hash 'name "lock" 'arity 1 'confirms? #f 'summary "show the lockfile plan")
        (hash 'name "why" 'arity 1 'confirms? #f 'summary "explain a package")
        (hash 'name "owner" 'arity 2 'confirms? #f 'summary "who owns a path")
        (hash 'name "verify" 'arity 1 'confirms? #f 'summary "verify a tree")
        (hash 'name "status" 'arity 2 'confirms? #f 'summary "what is installed")
        (hash 'name "held" 'arity 1 'confirms? #f 'summary "what is held")
        (hash 'name "outdated" 'arity 3 'confirms? #f 'summary "what is behind")
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

(struct mcp-session (token [spent #:mutable] [plan-digest #:mutable])
  #:transparent)

(define (make-session in out)
  (mcp-session (make-token) #f #f))

;; session -> string. 32 bytes from the OS CSPRNG (/dev/urandom), hex.
;; NOT a timestamp, NOT a counter, NOT anything reproducible: a token a
;; reader could guess is not a secret, and the constant it replaces was
;; published in the source. /dev/urandom is what the kernel already feeds
;; TLS session keys from, so this adds no dependency.
(define (make-token)
  (define in (open-input-file "/dev/urandom"))
  (define got (read-bytes 32 in))
  (close-input-port in)
  (cond
    [(and (bytes? got) (= (bytes-length got) 32))
     ;; Lowercase: security/commit-pinned? accepts lowercase hex only, and
     ;; a token spelled two ways is a token people mistype.
     (string-downcase (bytes->hex-string got))]
    [else
     ;; Never hand out a guessable token just to keep the protocol alive.
     (raise-pm-error 'internal 'make-token
                     "the system random source is short; no token issued"
                     #:fields `(("wanted" . 32)
                               ("got" . ,(if (bytes? got)
                                           (bytes-length got)
                                           0))))]))

(define (session-token s) (mcp-session-token s))

;; session -> boolean, true once this token has approved one call
(define (session-token-spent? s) (mcp-session-spent s))

;; session -> string or #f, the plan this token was issued for
(define (session-plan-digest s) (mcp-session-plan-digest s))

;; string-stringlist -> string, the plan digest a token is bound to: sha1
;; over the tool name and its arguments, using openssl/sha1 exactly as
;; machine/file-lock.rkt already does, so the tree keeps ONE hashing idiom.
;; This is an IDENTIFIER, not a MAC and not a signature: the safety rests
;; on the token being a secret and on it being single-use. It exists so a
;; token approved for one call cannot be presented for a different one.
(define (plan-digest name argv)
  (bytes->hex-string
   (sha1-bytes
    (open-input-string (string-join (cons name argv) " ")))))

;; session string -> void. THE TOKEN REQUEST: bind this token to the plan
;; the human approved. It does not block here -- the human approves outside
;; this process -- so it records the binding and returns. An already-spent
;; token is NOT re-bindable: one approval is one call, and a second
;; request must be a new token rather than a reused one.
(define (session-authorise! s digest)
  (when (mcp-session-spent s)
    (raise-pm-error 'config 'session-authorise!
                    "confirmation token already used"
                    #:fields `(("digest" . ,digest))))
  (set-mcp-session-plan-digest! s digest)
  (void))

;; string-stringlist session jsexpr -> (or/c string? #f). The refusal name
;; when this state-changing call may NOT proceed, #f when it may. Every
;; fact goes to the ONE shared predicate in security/, so this server and
;; the CLI answer the same question the same way.
(define (confirmation-refusal-for name argv sess args)
  (define given (hash-ref args 'confirmation #f))
  (confirmation-refusal (not (eq? given #f))
                        (equal? given (session-token sess))
                        (session-token-spent? sess)
                        (equal? (plan-digest name argv)
                                (session-plan-digest sess))))

;; string string -> string
;; The next step for a refusal is the refusal's own: telling an
;; already-spent caller to "pass the token" taught the wrong habit, so
;; each of the four reasons names its own way forward (D-070).
(define (refusal-text name refusal)
  (string-append
   name " changes state: " refusal "; "
   (cond
     [(string=? refusal "needs a confirmation token")
      "pass it as the confirmationToken argument"]
     [(string=? refusal "wrong confirmation token")
      "use the token initialize handed out"]
     [(string=? refusal "confirmation token already used")
      "it approves one call, so ask for a fresh token"]
     [(string=? refusal "confirmation token is for a different plan")
      "re-read the plan the token was issued for"]
     [else "ask for a human-approved token"])))

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
       [(member name '("events.runs" "events.tail" "run.get"))
        ;; Feed tools are answered here, never by run-tool: they read
        ;; the event file and spawn nothing.
        (run-feed-tool name argv id)]
       [(not (and (list? argv) (andmap string? argv)))
        (rpc-error id -32602 "tool arguments must be strings")]
       [(not (= (length argv) (hash-ref tool 'arity)))
        (rpc-error id -32602
                   (format "~a takes exactly ~a arguments"
                           name (hash-ref tool 'arity)))]
       ;; S-01: the policy names the state-changing set; the table
       ;; still carries confirms? for discovery, and the test below
       ;; asserts the two agree on every tool.
       [else
        (define refusal
          (if (state-changing? name)
              (confirmation-refusal-for name argv sess args)
              #f))
        (if refusal
            ;; WAIT door: a HUMAN is being asked here, so the feed says so
            ;; before the refusal goes out. Each of the four refusals keeps
            ;; its own name and its own next step (refusal-text), so a
            ;; caller can tell "nothing sent" from "wrong secret" from
            ;; "already spent" from "wrong plan" -- and "already spent"
            ;; never tells it to pass the token again.
            (wait-for (string->symbol name) "confirmation token"
                      (string-append name " changes state and was refused: "
                                     refusal)
                      #:how "the token initialize handed out"
                      (lambda ()
                        (rpc-error
                         id -32001
                         (refusal-text name refusal))))
            ;; Approved: spend the token NOW, before the call runs. One
            ;; approval, one call; a retry must ask again.
            (begin
              (when (state-changing? name)
                (set-mcp-session-spent! sess #t))
              (run-tool name argv id)))])]))

;; --- The event feed (V-4) ---------------------------------------------
;; Everything here reads <state>/events/<run-id>.jsonl, the file
;; core/verbose.rkt writes. Redaction already happened on the way IN,
;; so nothing read back here needs redoing; a value that reached the
;; feed is already safe to hand out.
;; The events dir, overridable so a test never reads the real state
;; root. Production never sets it.
(define current-feed-dir (make-parameter #f))

(define (feed-dir)
  (or (current-feed-dir) (default-events-dir)))

;; path-string -> boolean
(define (feed-exists? run-id)
  (file-exists? (build-path (feed-dir) (string-append run-id ".jsonl"))))

;; path-string -> (listof jsexpr), every line parsed, a half-written
;; last line ignored rather than fatal (the file is appended per event)
(define (feed-events run-id)
  (define path (build-path (feed-dir) (string-append run-id ".jsonl")))
  (if (not (file-exists? path))
      '()
      (for/list ([l (in-list (string-split (file->string path) "\n"))]
                 #:unless (string=? (string-trim l) ""))
        (with-handlers ([exn:fail? (lambda (_) #f)])
          (read-json (open-input-string l))))))

;; -> string or #f, the run pm says is active
(define (feed-current)
  (define p (build-path (feed-dir) "current"))
  (if (file-exists? p)
      (let ([s (string-trim (file->string p))])
        (if (string=? s "") #f s))
      #f))

;; -> (listof string), run ids, newest first by name
;; A run id is the file name minus ".jsonl". path-only returns #f for a
;; bare relative name, so this is plain string work on the file name.
(define (run-id-of f)
  (define nm (path->string (file-name-from-path f)))
  (substring nm 0 (- (string-length nm) (string-length ".jsonl"))))

(define (feed-runs)
  (define dir (feed-dir))
  (if (not (directory-exists? dir))
      '()
      (sort (map run-id-of
                 (filter (lambda (f)
                           (regexp-match? #rx"\\.jsonl$" (path->string f)))
                         (directory-list dir)))
            string<?)))

;; jsexpr -> string, one line per event for a human or a model.
;; seq is a NUMBER in the feed, so it is formatted, not appended.
(define (event->line e)
  (string-append "#" (format "~a" (hash-ref e 'seq "0"))
                 " " (hash-ref e 'kind "?")
                 " " (hash-ref e 'who "?")
                 ": " (hash-ref e 'what "")
                 (if (and (hash-ref e 'why '~f) (not (equal? (hash-ref e 'why) "record")))
                     (string-append " (" (hash-ref e 'why) ")")
                     "")
                 (if (hash-ref e 'how #f)
                     (string-append " [" (hash-ref e 'how) "]")
                     "")))

;; name (listof string) any -> jsexpr
(define (run-feed-tool name argv id)
  (cond
    [(string=? name "events.runs")
     (define runs (feed-runs))
     (rpc-ok id (hasheq 'runs runs
                        'current (or (feed-current) #f)
                        'count (length runs)))]
    [(string=? name "events.tail")
     (define run-id (car argv))
     (define from (string->number (cadr argv)))
     (if (not (feed-exists? run-id))
         (rpc-error id -32602 (string-append "no such run: " run-id))
         (let* ([all (filter (lambda (e) (and (hash? e) e)) (feed-events run-id))]
                ;; Strictly after: next-seq resumes cleanly with nothing
                ;; re-delivered, matching the OpenCode plugin's tailEvents.
                [after (filter (lambda (e) (> (hash-ref e 'seq 0) from)) all)]
                [shown (if (> (length after) 200)
                           (take-right after 200)
                           after)])
           (rpc-ok id
                   (hasheq 'run-id run-id
                           'from-seq from
                           'count (length after)
                           'lines (map event->line shown)
                           'next-seq (if (pair? shown)
                                        (hash-ref (last shown) 'seq)
                                        from)))))
     ]
    [(string=? name "run.get")
     (define run-id (car argv))
     (if (not (feed-exists? run-id))
         (rpc-error id -32602 (string-append "no such run: " run-id))
         (let* ([evs (filter (lambda (e) (and (hash? e) e)) (feed-events run-id))]
                [starts (filter (lambda (e) (equal? (hash-ref e 'kind) "START")) evs)]
                [ends (filter (lambda (e) (and (equal? (hash-ref e 'kind) "END")
                                                (= (hash-ref e 'depth 0) 0)))
                              evs)]
                [fails (filter (lambda (e) (equal? (hash-ref e 'kind) "FAIL")) evs)])
           (rpc-ok id
                   (hasheq 'run-id run-id
                           'events (length evs)
                           'started (if (pair? starts)
                                        (hash-ref (car starts) 'what #f)
                                        #f)
                           'ended (pair? ends)
                           'end-result (if (pair? ends)
                                            (hash-ref (last ends) 'result #f)
                                            #f)
                           'failures (map (lambda (e)
                                            (string-append (hash-ref e 'who '?:)
                                                           ": "
                                                           (hash-ref e 'what '?)
                                                           " -- "
                                                           (hash-ref e 'result '?)))
                                          fails)))))
     ]
    [else (rpc-error id -32602 (format "not a feed tool: ~a" name))]))

;; string (listof string) any -> jsexpr. Runs through the same parse
;; and run-command-json the CLI uses, so a refusal here is the refusal
;; a user would see on the command line.
(define (run-tool name argv id)
  ;; Three classes of failure, three different answers.
  ;;
  ;; exn:fail:pm? is pm's own refusal and is already a well-formed
  ;; message. exn:fail:filesystem? and exn:fail:contract? are what the
  ;; CALLER's arguments cause -- a specs directory that does not exist, a
  ;; lockfile that is not there -- and they belong with the refusals, at
  ;; -32000, because from the caller's side that is a command that could
  ;; not run, not a broken server. Before this, `pm apply /no/such/dir`
  ;; came back as -32603 Internal error with a raw exn message: true,
  ;; useless, and it taught a client that the server was at fault.
  ;;
  ;; Everything else still reaches the catch-all in handle-message and
  ;; stays -32603, so a genuine server fault is still reported as one.
  (with-handlers
      ([exn:fail:pm?
        (lambda (e)
          (rpc-error id -32000 (exn-message e)))]
       [exn:fail:filesystem?
        (lambda (e)
          (rpc-error id -32000 (exn-message e)))]
       [exn:fail:contract?
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
   '("activate" "apply" "check" "events.runs" "events.tail"
     "fetch" "held" "hold" "lock" "outdated" "owner" "plan" "remove"
     "rollback" "run.get" "status" "update" "verify" "why"))
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
  (check-equal? (length (regexp-match* #rx"\"name\":\"[a-z.]+\"" table)) 19)
  (check-true
   (regexp-match?
    #rx"\\{\"name\":\"apply\",\"arity\":1,\"confirmsConfirmation\":true"
    table))
  (check-true
   (regexp-match?
    #rx"\\{\"name\":\"plan\",\"arity\":1,\"confirmsConfirmation\":false"
    table))
  ;; S-01: the discovery table and the enforcement policy agree on
  ;; every tool; a new command cannot be added to one and not the other.
  (for ([t (in-list pm-tools)])
    (check-equal? (hash-ref t 'confirms?)
                  (state-changing? (hash-ref t 'name))
                  (hash-ref t 'name)))

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

  ;; With the RIGHT token the command RUNS. The gate is the token, not
  ;; executability: apply is a live command now (D-040), so what comes
  ;; back is its own honest failure about the specs directory we named --
  ;; not "not executable". Asserting the ABSENCE of the old stub refusal
  ;; is deliberate: it is what proves the state-changing tool reached the
  ;; engine instead of stopping at the surface.
  ;;
  ;; CHANGED BY THE NEW RULES, and this is why: the token used to be a
  ;; constant compared for equality, so "right token" was the whole gate.
  ;; A token is now issued for ONE plan and spent by one call, so a right
  ;; token that was never bound to this plan must refuse with "a
  ;; different plan". Binding it here is what the rule forces; the
  ;; assertions below are untouched and still pass for the same reason.
  (session-authorise! sess (plan-digest "apply" (list "state")))
  (define right-token
    (rpc 6 "tools/call"
          (hasheq 'name "apply"
                  'arguments (list "state")
                  'confirmation (session-token sess))))
  (define right-token-error (hash-ref right-token 'error))
  (check-equal? (hash-ref right-token-error 'code) -32000)
  (define right-token-msg (hash-ref right-token-error 'message))
  (check-false (regexp-match? #rx"not executable" right-token-msg))
  (check-true (regexp-match? #rx"state" right-token-msg))

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

  ;; --- the feed tools read a real synthetic run (regression) ---------
  ;; feed-events once iterated the whole file as one string and treated
  ;; read-json as a parameter, so every tail came back -32603 with no
  ;; result key. The skill test caught it; this test keeps it caught
  ;; here, in the module that owns the bug.
  (define feed-dir
    (build-path (find-system-path 'temp-dir) "pm-mcp-feed"))
  (when (directory-exists? feed-dir)
    (delete-directory/files feed-dir))
  (define feed-run
    (parameterize ([verbose-screen? #f])
      (define id (begin-run! #:who 'test #:events-dir feed-dir))
      (with-op 'fetch "pkg-alpha" "synthetic run for the feed tools"
               #:inputs '("pkg-alpha")
               (lambda ()
                 (step 'fetch "download" "the fixture has no bytes to move")
                 (skip 'fetch "verify" "the fixture source is already local")
                 "pkg-alpha"))
      (end-run! "exit=0")
      id))
  (define (feed-rpc id name args)
    (parameterize ([current-feed-dir feed-dir])
      (rpc id "tools/call" (hasheq 'name name 'arguments args))))
  (define feed-runs-reply (feed-rpc 10 "events.runs" '()))
  (check-not-false
   (member feed-run
           (hash-ref (hash-ref feed-runs-reply 'result) 'runs)))
  (check-equal? (hash-ref (hash-ref feed-runs-reply 'result) 'current)
                feed-run)
  (define feed-tail-reply (feed-rpc 11 "events.tail" (list feed-run "0")))
  (define feed-tail (hash-ref feed-tail-reply 'result))
  (check-true (> (hash-ref feed-tail 'count) 3))
  ;; From "0" the run START itself (seq 0) is excluded; the first line
  ;; is the fetch op that opened inside it.
  (check-true
   (regexp-match? #rx"^#1 START fetch"
                  (car (hash-ref feed-tail 'lines))))
  (check-true
   (regexp-match? #rx"SKIP fetch"
                  (string-join (hash-ref feed-tail 'lines) "\n")))
  (define feed-again
    (feed-rpc 12 "events.tail"
              (list feed-run (number->string (hash-ref feed-tail 'next-seq)))))
  (check-equal? (hash-ref (hash-ref feed-again 'result) 'count) 0)
  (define feed-get-reply (feed-rpc 13 "run.get" (list feed-run)))
  (define feed-summary (hash-ref feed-get-reply 'result))
  (check-equal? (hash-ref feed-summary 'ended) #t)
  (check-equal? (hash-ref feed-summary 'end-result) "exit=0")
  (check-true (>= (hash-ref feed-summary 'events) 5))
  (define feed-missing
    (feed-rpc 14 "run.get" (list "pm-no-such-run")))
  (check-equal? (hash-ref (hash-ref feed-missing 'error) 'code) -32602)
  (delete-directory/files feed-dir)

  (delete-directory/files fixture))
