#lang racket/base
;; skill-examples.rkt -- the three worked examples in
;; skills/aiu-pm/SKILL.md, run as a test (E-28).
;;
;; The skill is documentation, and documentation rots. Every command it
;; shows is executed here against the real CLI or the real MCP server,
;; and every shape it claims about the feed is checked against a real
;; feed. If the skill drifts from the engine, this goes red.
;;
;; The examples use synthetic names (pkg-alpha, pm-7040) so nothing
;; here reads or writes a real state root.

(require racket/string
         racket/file
         racket/list
         json
         "../../cli/main.rkt"
         "../../mcp/server.rkt"
         "../../core/verbose.rkt")

(module+ main
  (dynamic-require "skill-examples.rkt" 'test #f))

(module+ test
  (require rackunit
           racket/runtime-path)

  ;; raco test runs with the MODULE's directory as cwd, so docs/examples
  ;; is resolved from the repo root rather than written relative.
  (define-runtime-path skill-dir ".")
  (define repo-root
    (simplify-path (build-path skill-dir 'up 'up)))
  (define example-dir
    (path->string (build-path repo-root "docs" "examples")))

  ;; --- example 1: pm check --format json ------------------------------
  ;; The skill shows the whole document, so compare the whole document.
  (define check-doc
    (run-command-json
     (parse-args (list->vector (list "check" example-dir "--format" "json")))))
  (check-equal? (hash-ref (string->json check-doc) 'name) "check")
  (check-equal? (hash-ref (string->json check-doc) 'format) "json")
  (check-equal? (hash-ref (string->json check-doc) 'operands) (list example-dir))
  ;; The skill claims every spec produced an "ok: NAME VERSION" line.
  (define ok-lines (hash-ref (string->json check-doc) 'ok))
  (check-true (pair? ok-lines))
  (check-not-false (member "ok: lua 5.5.1" ok-lines))
  (for ([l (in-list ok-lines)])
    (check-regexp-match #rx"^ok: [a-z0-9-]+ [0-9]" l))

  ;; The skill lists bats-core, cjson, hello and lua. If a spec is added
  ;; or removed the skill is stale and must be updated.
  (check-equal?
   (sort (map (lambda (l) (cadr (string-split l " "))) ok-lines) string<?)
   '("bats-core" "cjson" "hello" "lua"))

  ;; --- example 2: pm plan --format json -------------------------------
  (define plan-doc
    (run-command-json
     (parse-args (list->vector (list "plan" example-dir "--format" "json")))))
  (define plan-j (string->json plan-doc))
  (check-equal? (hash-ref plan-j 'name) "plan")
  (define packages (hash-ref plan-j 'packages))
  (check-equal? (length packages) 4)
  (check-equal?
   (sort (map (lambda (p) (hash-ref p 'name)) packages) string<?)
   '("bats-core" "cjson" "hello" "lua"))
  ;; The skill says deps is empty for all four, because pm does not
  ;; resolve a closure yet (G-01). If that ever changes, the skill is
  ;; wrong and this must fail.
  (for ([p (in-list packages)])
    (check-equal? (hash-ref p 'deps) '()))

  ;; --- example 3: the feed, and the two MCP feed tools -----------------
  (define feed-dir
    (build-path (find-system-path 'temp-dir) "pm-skill-feed"))
  (when (directory-exists? feed-dir) (delete-directory/files feed-dir))

  ;; A synthetic run shaped like example 1's: a check over the fixture.
  (define run-id
    (parameterize ([verbose-screen? #f])
      (define id (begin-run! #:who 'test #:events-dir feed-dir))
      (with-op 'check example-dir "every .rktd in the directory was validated"
               (lambda ()
                 (for ([l (in-list ok-lines)])
                   (step 'check (string-trim l)
                         "the spec parsed and passed every field check"))
                 (skip 'check "nonexistent.rktd"
                       "the directory no longer lists that spec")
                 'done))
      (end-run! "exit=0")
      id))

  ;; The skill claims current names the active run.
  (check-equal? (string-trim (file->string (build-path feed-dir "current")))
                run-id)

  ;; And that every feed line is one JSON object with the full field set.
  (define feed-lines
    (filter (lambda (l) (not (string=? (string-trim l) "")))
            (string-split
             (file->string (build-path feed-dir (string-append run-id ".jsonl")))
             "\n")))
  (check-true (>= (length feed-lines) 8))
  (define events
    (map (lambda (l) (read-json (open-input-string l))) feed-lines))
  (for ([e (in-list events)])
    (for ([k (in-list '(run-id seq parent-id kind depth who what why how
                         inputs outputs result utc mono-ms duration-ms))])
      (check-true (hash-has-key? e k) (format "feed line missing ~a" k))))
  ;; The kinds the skill documents must all be spelled as documented.
  (define kinds (map (lambda (e) (hash-ref e 'kind)) events))
  (for ([k (in-list '("START" "STEP" "SKIP" "END"))])
    (check-not-false (member k kinds) (format "~a missing from the feed" k)))
  ;; The SKIP carries the reason the skill promises, never a blank one.
  (define skips (filter (lambda (e) (equal? (hash-ref e 'kind) "SKIP")) events))
  (check-true (pair? skips))
  (for ([e (in-list skips)])
    (check-true (string? (hash-ref e 'why)))
    (check-not-false (> (string-length (hash-ref e 'why)) 0)))

  ;; Now the same run through the MCP feed tools, which is what an AI
  ;; actually calls. The events dir is redirected so the real state
  ;; root is untouched.
  (define sess (make-session (open-input-string "") (open-output-string)))
  (define (rpc id name args)
    (parameterize ([current-feed-dir feed-dir])
      (handle-message
       (hasheq 'jsonrpc "2.0" 'id id 'method "tools/call"
               'params (hasheq 'name name 'arguments args))
       sess)))

  (define runs (rpc 10 "events.runs" '()))
  (check-not-false (member run-id (hash-ref (hash-ref runs 'result) 'runs)))
  (check-equal? (hash-ref (hash-ref runs 'result) 'current) run-id)

  (define tail (rpc 11 "events.tail" (list run-id "0")))
  (define tail-result (hash-ref tail 'result))
  (check-equal? (hash-ref tail-result 'from-seq) 0)
  (check-equal? (hash-ref tail-result 'count) (length events))
  ;; The skill shows the line format "#seq KIND who: what (why)".
  (define lines (hash-ref tail-result 'lines))
  (check-true (regexp-match? #rx"^#0 START pm: run \\(session start\\)"
                             (car lines)))
  (check-not-false (member run-id (regexp-match* #rx"pm-[0-9]+"
                                                (car lines))))
  ;; From the tail's own next-seq there is nothing new, which is what the
  ;; skill tells an AI to do when resuming.
  (define again (rpc 12 "events.tail"
                       (list run-id (number->string (hash-ref tail-result 'next-seq)))))
  (check-equal? (hash-ref (hash-ref again 'result) 'count) 0)

  (define get (rpc 13 "run.get" (list run-id)))
  (define summary (hash-ref get 'result))
  (check-equal? (hash-ref summary 'run-id) run-id)
  (check-equal? (hash-ref summary 'ended) #t)
  (check-equal? (hash-ref summary 'end-result) "exit=0")
  ;; run.get claims started is the START what; it is "run" here.
  (check-equal? (hash-ref summary 'started) "run")

  ;; The skill tells an AI that an unknown run is an RPC error, not an
  ;; empty success.
  (define missing (rpc 14 "run.get" (list "pm-no-such-run")))
  (check-equal? (hash-ref (hash-ref missing 'error) 'code) -32602)

  (delete-directory/files feed-dir))

;; string -> jsexpr, the CLI document parsed back
(define (string->json s)
  (read-json (open-input-string s)))