#lang racket/base
;; One job: the MCP server — the same commands, over stdio, read free
;; and mutate gated. Registered in plan/package-tree.org; lands with
;; TODO item 15.
;;
;; The server speaks JSON-RPC 2.0 over the standard input and the
;; standard output: one request per line, one answer per line. It
;; answers with the one envelope, so an agent reads this server and the
;; CLI the same way.
;;
;; Read is free: a read tool runs without a human. Mutate is gated: a
;; mutating tool needs the human's token, and the ENGINE re-checks it —
;; the server does not take the caller's word for what a tool does, and
;; it compares the declaration against the security predicate before it
;; runs anything (rule 07).
;;
;; The exit codes are frozen: 0 when every request was answered, 2 when
;; a request was refused (and the refusal named the rule it refused
;; by), 3 when the server could not answer at all.
;;
;; The editing session is NOT a tool here: it reads the terminal, and
;; the terminal is not in this conversation. The CLI keeps it.
;;
;; Registered in plan/package-tree.org; lands with TODO item 15.

(require json
         racket/file
         racket/list
         racket/port
         racket/string
         "../machine/directories.rkt"
         "../security/security.rkt"
         "capabilities.rkt"
         "dispatch.rkt"
         "documents.rkt")

;; protocol-version is the MCP protocol the server speaks.
(define protocol-version "2024-11-05")

;; rule-gate is the rule a change is gated by, named in the refusal.
(define rule-gate
  "rule 07: read is free, a change needs the human's token")

;; rule-declaration is the rule a lying declaration is refused by.
(define rule-declaration
  "rule 07: the declaration and the security predicate must agree")

;; engine-token answers the human's token: the environment first, then
;; the file in the state directory. The empty text means there is no
;; token, and a change is refused.
(define (engine-token)
  (define from-env (getenv "AIU_EDITOR_TOKEN"))
  (if (and from-env (not (string=? from-env "")))
      from-env
      (token-from-file)))

;; token-from-file answers the token from the state directory, or the
;; empty text when the file is not there or holds nothing.
(define (token-from-file)
  (define path (build-path (state-dir) "permit-token"))
  (if (not (file-exists? path))
      ""
      (with-handlers ([exn:fail? (lambda (why) "")])
        (define line (read-line (open-input-file path)))
        (if (eof-object? line) "" (string-trim line)))))

;; token-given? answers whether the arguments carry the human's token:
;; the engine compares it with its own, so a caller cannot grant itself
;; the right to change the tree.
(define (token-given? arguments)
  (define given (hash-ref arguments 'confirm ""))
  (define own (engine-token))
  (and (string? given)
       (not (string=? given ""))
       (not (string=? own ""))
       (string=? given own)))

;; main runs the server: one request per line, one answer per line. The
;; exit code says what happened: 0 for every request answered, 2 for a
;; refusal, 3 when the server could not answer at all.
(define (main)
  (define refused
    (let loop ([refused #f])
      (define line (read-line (current-input-port)))
      (if (eof-object? line)
          refused
          (let* ([answer (handle-request line)]
                 [said (or refused (refusal-in? answer))])
            (when answer
              (displayln answer)
              (flush-output (current-output-port)))
            (loop said)))))
  ;; the exit codes are frozen: a refusal is 2, an answer is 0
  (exit (if refused exit-refusal exit-ok)))

;; refusal-in? answers whether an answer line carries a refusal: the
;; envelope names the rule it refused by.
(define (refusal-in? line)
  (define env (envelope-in line))
  (and env
       (hash? (hash-ref env 'refusal #f))
       (not (null? (hash-ref env 'refusal '())))))

;; handle-request answers one line of JSON-RPC: the answer line, or
;; nothing when the request was a notification (a request with no id).
(define (handle-request line)
  (define request
    (with-handlers ([exn:fail? (lambda (why) #f)])
      (read-json (open-input-string line))))
  (if (not (hash? request))
      (json-line (jsonrpc-error #f -32700 "the request is not JSON"))
      (let ([id (if (hash-has-key? request 'id) (hash-ref request 'id) #f)]
            [method (hash-ref request 'method "")]
            [params (hash-ref request 'params (hash))])
        (define answer (run-method method params))
        (if (not (hash-has-key? request 'id))
            #f
            (json-line (jsonrpc-answer id answer))))))

;; run-method answers the method of a request: either a result or an
;; error.
(define (run-method method params)
  (cond
    [(string=? method "initialize")
     (hash 'result
           (hash 'protocolVersion protocol-version
                 'capabilities (hash 'tools (hash))
                 'serverInfo (hash 'name program-name 'version envelope-version)))]
    [(string=? method "ping") (hash 'result (hash))]
    [(string=? method "tools/list") (hash 'result (hash 'tools (tool-list)))]
    [(string=? method "tools/call") (hash 'result (tool-call params))]
    [else (hash 'error (hash 'code -32601
                              'message (format "there is no method named ~a" method)))]))

;; tool-list answers the tools: the declaration, as MCP wants it.
(define (tool-list)
  (for/list ([cap (in-list the-capabilities)])
    (hash 'name (capability-name cap)
          'description (capability-description cap)
          'inputSchema
          (hash 'type "object"
                'properties
                (hash 'args (hash 'type "array"
                                   'description "the arguments of the command, in order")
                      'confirm (hash 'type "string"
                                     'description "the human's token; a change needs it"))
                'required (if (capability-mutating cap) '("confirm") '())))))

;; tool-call runs one tool and answers the MCP result: the envelope as
;; the text, and whether it was a refusal.
(define (tool-call params)
  (define name (hash-ref params 'name ""))
  (define arguments (hash-ref params 'arguments (hash)))
  (define cap (capability-of name))
  (cond
    [(not cap)
     (mcp-error -32602 (format "there is no tool named ~a" name))]
    [(not (declaration-agrees? name))
     (mcp-refusal
      (refusal-document "tool" rule-declaration
                        (format "the declaration and the security predicate disagree about ~a, so it was refused"
                                name)))]
    [(and (capability-mutating cap) (not (token-given? arguments)))
     (mcp-refusal
      (refusal-document "tool" rule-gate
                        (format "~a changes the tree, so it needs the human's token, and it was refused"
                                name)))]
    [else
     (mcp-result
      (make-document "tool" #t
                     (hash 'text (run-the-tool name (tool-args arguments)))
                     #f
                     '()))]))

;; tool-args answers the positional arguments of a tool, as the CLI
;; takes them: a list of words.
(define (tool-args arguments)
  (define raw (hash-ref arguments 'args '()))
  (if (list? raw)
      (map (lambda (v) (if (string? v) v (format "~a" v))) raw)
      '()))

;; run-the-tool runs the command the tool names and answers its text.
;; The text is the text the CLI prints: one dispatch, one voice.
(define (run-the-tool name args)
  (define out (open-output-string))
  (parameterize ([current-output-port out])
    (run-verb name args))
  (get-output-string out))

;; mcp-result answers the MCP result of an envelope: the envelope as the
;; text, and whether it was a refusal.
(define (mcp-result doc)
  (hash 'content (list (hash 'type "text" 'text (document-line doc)))
        'isError (not (document-ok doc))))

;; mcp-refusal answers the MCP result of a refusal: the same shape, and
;; the refusal names its rule.
(define (mcp-refusal doc)
  (mcp-result doc))

;; mcp-error answers the MCP error of a call that never ran.
(define (mcp-error code message)
  (hash 'error (hash 'code code 'message message)))

;; jsonrpc-answer answers the JSON-RPC line of one answer: the result
;; or the error, with the id that asked for it.
(define (jsonrpc-answer id answer)
  (if (hash-has-key? answer 'error)
      (hash 'jsonrpc "2.0" 'id id 'error (hash-ref answer 'error))
      (hash 'jsonrpc "2.0" 'id id 'result (hash-ref answer 'result #f))))

;; jsonrpc-error answers the JSON-RPC line of a request that could not
;; be read at all.
(define (jsonrpc-error id code message)
  (hash 'jsonrpc "2.0" 'id id 'error (hash 'code code 'message message)))

;; json-line answers one line of JSON.
(define (json-line value)
  (define out (open-output-string))
  (write-json value out)
  (get-output-string out))

;; envelope-in answers the envelope inside an answer line, or nothing when
;; the line holds no envelope: the answer of a tool is the envelope as
;; the text.
(define (envelope-in line)
  (if (not line)
      #f
      (let* ([parsed
              (with-handlers ([exn:fail? (lambda (why) #f)])
                (read-json (open-input-string line)))]
             [result (if (hash? parsed) (hash-ref parsed 'result #f) #f)]
             [content (if (hash? result) (hash-ref result 'content '()) '())]
             [first (if (null? content) #f (car content))]
             [text (if (hash? first) (hash-ref first 'text "") "")])
        (if (string=? text "")
            #f
            (with-handlers ([exn:fail? (lambda (why) #f)])
              (read-json (open-input-string text)))))))

;; The server, when it is run.
(module+ main
  (main))

;; The pieces of the server, for the gate that proves the kit.
(provide protocol-version
         rule-gate
         rule-declaration
         engine-token
         main
         handle-request
         run-method
         tool-list
         tool-call
         run-the-tool
         refusal-in?
         envelope-in)
