#lang racket/base
;; One job: the kit conformance check — the six proofs the kit format
;; names. Registered in plan/package-tree.org; lands with TODO item 15.
;;
;; The six proofs, one by one, and each one is real — it runs the thing
;; it proves and reads the answer back:
;;   1. the one envelope honored
;;   2. frozen exit codes with refusals naming their rule
;;   3. MCP gating with the engine's own re-check
;;   4. skill examples executed by the suite
;;   5. the plugin proven read-only
;;   6. the feed flushed and the wait door held
;;
;; A proof that checks nothing says NOTHING, and a proof that fails
;; names what failed. The exit code is the answer: 0 when the six hold,
;; 3 when one of them does not.
;;
;; Registered in plan/package-tree.org; lands with TODO item 15.

(require json
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         racket/system
         "../editor/src/entry/capabilities.rkt"
         "../editor/src/entry/dispatch.rkt"
         "../editor/src/entry/documents.rkt"
         "../editor/src/entry/mcp.rkt"
         "../editor/src/machine/directories.rkt"
         "../editor/src/narration/wait-door.rkt")

;; project-dir is the editor's directory: the one that holds the package
;; and the gate. The search walks up from where the check runs, because
;; this Racket does not say where the script itself sits.
(define project-dir
  (let loop ([at (simplify-path (current-directory))])
    (define up (simplify-path (build-path at "..")))
    (cond
      [(and (directory-exists? (build-path at "editor" "src"))
            (directory-exists? (build-path at "gate")))
       at]
      [(string=? (path->string at) (path->string up)) at]
      [else (loop up)])))

;; cli-path is the CLI the skill's examples run.
(define cli-path
  (build-path project-dir "editor" "src" "entry" "cli.rkt"))

;; skill-path is the skill file: the examples come from it.
(define skill-path
  (build-path (build-path project-dir "..") "agent" "skills" "editor" "SKILL.md"))

;; plugin-path is the read-only watcher.
(define plugin-path
  (build-path (build-path project-dir "..") "agent" "opencode-plugin" "editor-watch.js"))

;; scratch-dir is where the proofs that need a file put theirs.
(define scratch-dir
  (build-path (or (getenv "TMPDIR") "/tmp") "aiu-kit-check"))

;; token is the human's token the gate uses to prove the gate: the
;; engine checks it itself, so the gate holds one too.
(define token "kit-check-token")

;; main runs the six proofs and answers the verdict.
(define (main)
  (ensure-dir scratch-dir)
  (putenv "AIU_EDITOR_TOKEN" token)
  (define problems '())
  (set! problems (append problems (proof-envelope)))
  (set! problems (append problems (proof-exit-codes)))
  (set! problems (append problems (proof-gating)))
  (set! problems (append problems (proof-skill)))
  (set! problems (append problems (proof-plugin)))
  (set! problems (append problems (proof-feed-and-door)))
  (if (null? problems)
      (begin
        (displayln "OK kit-check — the six proofs hold: the one envelope, the frozen codes, the gating, the skill examples, the read-only plugin, and the flushed feed with the wait door held")
        (exit exit-ok))
      (begin
        (for ([problem (in-list problems)]) (displayln (format "KIT — ~a" problem)))
        (displayln (format "KIT — ~a of the six proofs do not hold" (length problems)))
        (exit exit-cannot-run))))

;; proof-envelope proves that every surface answers in the one envelope:
;; the MCP's answer carries the envelope's fields, and the CLI's text is
;; the MCP's text, because there is one dispatch.
(define (proof-envelope)
  (define problems '())
  (define env
    (envelope-in
     (handle-request
      (json-text (hash 'jsonrpc "2.0" 'id 1 'method "tools/call"
                        'params (hash 'name "routes" 'arguments (hash)))))))
  (if (not env)
      (set! problems (cons "the MCP did not answer in the one envelope" problems))
      (begin
        (for ([field (in-list '(program version kind ok data refusal events))])
          (unless (hash-has-key? env field)
            (set! problems (cons (format "the envelope has no ~a field" field) problems))))
        (unless (string=? (hash-ref env 'program "") program-name)
          (set! problems (cons "the envelope names another program" problems)))
        (unless (hash-ref env 'ok #f)
          (set! problems (cons "the envelope says the read did not answer" problems)))))
  (define cli-text (capture (lambda () (run-verb "routes" '()))))
  (if (and env (hash? (hash-ref env 'data #f)))
      (unless (string=? (hash-ref (hash-ref env 'data) 'text "") cli-text)
        (set! problems (cons "the CLI and the MCP did not answer with the same text" problems)))
      (set! problems (cons "the envelope carries no data to compare with the CLI" problems)))
  problems)

;; proof-exit-codes proves the frozen exit codes and that a refusal
;; names its rule: the CLI refuses an unknown verb with the refusal
;; code, and the MCP's refusal envelope names the rule it refused by.
(define (proof-exit-codes)
  (define problems '())
  (unless (and (= exit-ok 0) (= exit-refusal 2) (= exit-cannot-run 3))
    (set! problems (cons "the exit codes are not the frozen ones" problems)))
  (define code
    (run-code (format "~a ~a no-such-verb >/dev/null 2>&1"
                       (racket-bin) (shell-quote (path->string cli-path)))))
  (unless (= code exit-refusal)
    (set! problems (cons (format "the CLI refused with code ~a, and the frozen refusal code is ~a"
                                 code exit-refusal)
                          problems)))
  (define refused
    (envelope-in
     (handle-request
      (json-text (hash 'jsonrpc "2.0" 'id 2 'method "tools/call"
                        'params (hash 'name "send" 'arguments (hash)))))))
  (if (and refused (hash? (hash-ref refused 'refusal #f)))
      (unless (not (string=? (hash-ref (hash-ref refused 'refusal) 'rule "") ""))
        (set! problems (cons "the refusal names no rule" problems)))
      (set! problems (cons "the MCP's refusal carried no rule" problems)))
  problems)

;; proof-gating proves that a change needs the human's token, that the
;; engine checks the token itself, and that the engine re-checks the
;; declaration against the security predicate.
(define (proof-gating)
  (define problems '())
  ;; a change with no token at all
  (define without
    (envelope-in
     (handle-request
      (json-text (hash 'jsonrpc "2.0" 'id 3 'method "tools/call"
                        'params (hash 'name "checkpoint" 'arguments (hash)))))))
  (if (and without (not (hash-ref without 'ok #f)))
      (unless (not (string=? (hash-ref (hash-ref without 'refusal #f) 'rule "") ""))
        (set! problems (cons "the refusal without the token names no rule" problems)))
      (set! problems (cons "a change without the human's token was not refused" problems)))
  ;; a change with the WRONG token
  (define wrong
    (envelope-in
     (handle-request
      (json-text (hash 'jsonrpc "2.0" 'id 4 'method "tools/call"
                        'params (hash 'name "checkpoint"
                              'arguments (hash 'confirm "not-the-token")))))))
  (if (and wrong (not (hash-ref wrong 'ok #f)))
      #t
      (set! problems (cons "a change with the wrong token was not refused" problems)))
  ;; a change with the RIGHT token runs: the engine checks the token
  ;; itself, and the tool does what it says
  (define right
    (envelope-in
     (handle-request
      (json-text (hash 'jsonrpc "2.0" 'id 5 'method "tools/call"
                        'params (hash 'name "stop"
                              'arguments (hash 'args '("start") 'confirm token)))))))
  (if (and right (hash-ref right 'ok #f))
      #t
      (set! problems (cons "a change with the human's token was refused anyway" problems)))
  ;; the engine's own re-check: the declaration agrees with the security
  ;; predicate about every tool
  (define liar (declaration-honest?))
  (if liar
      (set! problems (cons (format "the declaration lies about ~a" liar) problems))
      #t)
  ;; and the server really asks that question before it runs anything
  (unless (string-contains? (file->string (build-path project-dir "editor" "src" "entry" "mcp.rkt"))
                             "declaration-agrees?")
    (set! problems (cons "the server does not re-check the declaration" problems)))
  problems)

;; proof-skill proves that the skill's examples run: every example in
;; the skill file is executed, and each one must answer.
(define (proof-skill)
  (define problems '())
  (define examples (skill-examples))
  (if (null? examples)
      (set! problems (cons "the skill holds no example to run" problems))
      (for ([example (in-list examples)])
        (define code (run-code example))
        (unless (= code 0)
          (set! problems (cons (format "the example did not answer: ~a (code ~a)" example code)
                               problems)))))
  problems)

;; run-code runs a shell command and answers the exit code it left. The
;; code is asked of the shell through a file, because this Racket's
;; system answers yes or no and not the code the command left.
(define (run-code command)
  (define code-file (build-path scratch-dir "exit-code"))
  (when (file-exists? code-file) (delete-file code-file))
  (system (format "~a; echo $? > ~a 2>/dev/null"
                  command (shell-quote (path->string code-file))))
  (if (file-exists? code-file)
      (string->number (string-trim (file->string code-file)))
      #f))

;; starts-with? answers whether a text begins with a piece. The test is
;; written here because this Racket has no string-starts-with?.
(define (starts-with? text prefix)
  (and (>= (string-length text) (string-length prefix))
       (string=? (substring text 0 (string-length prefix)) prefix)))

;; skill-examples answers the runnable examples of the skill file: the
;; lines that begin with the program name. They are run from the
;; editor's directory, because that is where the paths in them point.
(define (skill-examples)
  (for/list ([line (in-list (lines-of skill-path))]
             #:when (starts-with? (string-trim line) "racket "))
    (define trimmed (string-trim line))
    (format "cd ~a && ~a ~a >/dev/null 2>&1"
            (shell-quote (path->string project-dir))
            (shell-quote (path->string (racket-bin)))
            (substring trimmed (string-length "racket ")))))

;; proof-plugin proves the watcher is read-only: its source holds no
;; write call, and running it against a file leaves the file as it was.
(define (proof-plugin)
  (define problems '())
  (define source (file->string plugin-path))
  (for ([call (in-list '("writeFileSync" "appendFileSync" "createWriteStream"
                          "unlinkSync" "rmSync" "mkdirSync" "renameSync"
                          "copyFileSync" "truncateSync" "chmodSync" "openSync"))])
    (when (string-contains? source call)
      (set! problems (cons (format "the plugin holds a write call: ~a" call) problems))))
  (define watched (build-path scratch-dir "watched.txt"))
  (call-with-output-file watched
    (lambda (port) (display "the first line\n" port))
    #:exists 'truncate)
  (define before (file->string watched))
  (define code
    (run-code (format "~a ~a ~a >/dev/null 2>&1"
                       (shell-quote (node-bin))
                       (shell-quote (path->string plugin-path))
                       (shell-quote (path->string watched)))))
  (unless (= code 0)
    (set! problems (cons "the plugin did not run" problems)))
  (unless (string=? before (file->string watched))
    (set! problems (cons "the plugin changed the file it watches" problems)))
  problems)

;; node-bin answers the program that runs the plugin, or nothing when
;; there is none: the proof then says what it could not do.
(define (node-bin)
  (define named (getenv "AIU_NODE_BIN"))
  (if (and named (not (string=? named "")))
      named
      (let ([found (find-executable-path "node")])
        (if found found "node"))))

;; find-executable-path answers where a program is, or nothing when it is
;; not there.
(define (find-executable-path name)
  (define dirs (getenv "PATH"))
  (if (not dirs)
      #f
      (for/or ([dir (in-list (string-split dirs ":"))])
        (define candidate (build-path dir name))
        (and (file-exists? candidate) (path->string candidate)))))

;; proof-feed-and-door proves the feed is flushed and the wait door is
;; held: the journal holds whole records after a session, and a wait
;; with no reason is refused.
(define (proof-feed-and-door)
  (define problems '())
  ;; the feed: a scratch file, a session that edits it, and the journal
  ;; the session left behind
  (define scratch (build-path scratch-dir "feed.txt"))
  (call-with-output-file scratch
    (lambda (port) (display "the first line\n" port))
    #:exists 'truncate)
  (define journal (journal-path-for scratch))
  (when (file-exists? journal) (delete-file journal))
  (define code
    (run-code (format "cd ~a && printf 'insert hello\\nshow\\nquit\\n' | ~a ~a edit ~a >/dev/null 2>&1"
                       (shell-quote (path->string project-dir))
                       (shell-quote (path->string (racket-bin)))
                       (shell-quote (path->string cli-path))
                       (shell-quote (path->string scratch)))))
  (unless (= code 0)
    (set! problems (cons "the session did not run, so the feed was not proved" problems)))
  (if (file-exists? journal)
      (let* ([text (file->string journal)]
             [whole (and (> (string-length text) 0)
                         (char=? (string-ref text (sub1 (string-length text))) #\newline))]
             [records (filter (lambda (line) (not (string=? line "")))
                               (string-split text "\n"))])
        (unless whole
          (set! problems (cons "the feed's last record is not whole: it was not flushed" problems)))
        (unless (> (length records) 0)
          (set! problems (cons "the feed holds no record" problems))))
      (set! problems (cons "the session left no feed behind" problems)))
  ;; the wait door: a wait with no reason is refused, and a wait with
  ;; no event is refused
  (unless (wait-refused "" "the event that ends it")
    (set! problems (cons "the wait door held a wait with no reason" problems)))
  (unless (wait-refused "the reason" "")
    (set! problems (cons "the wait door held a wait with no event" problems)))
  problems)

;; wait-refused answers whether the wait door refused a wait: it raises
;; when the why or the event is missing.
(define (wait-refused why on-event)
  (with-handlers ([exn:fail? (lambda (why) #t)])
    (capture (lambda () (wait-for "the kit check" "the feed" why on-event)))
    #f))

;; capture answers the text a piece of work printed.
(define (capture work)
  (define out (open-output-string))
  (parameterize ([current-output-port out]) (work))
  (get-output-string out))

;; json-text answers one line of JSON for a value.
(define (json-text value)
  (define out (open-output-string))
  (write-json value out)
  (get-output-string out))

;; shell-quote answers a text that a shell will read as one word.
(define (shell-quote text)
  (string-append "'" (string-replace text "'" "'\\''") "'"))

;; lines-of answers the lines of a file, or the empty list when the file
;; cannot be read.
(define (lines-of path)
  (with-handlers ([exn:fail? (lambda (why) '())])
    (call-with-input-file path
      (lambda (port)
        (let loop ([out '()])
          (define line (read-line port))
          (if (eof-object? line)
              (reverse out)
              (loop (cons line out))))))))

;; The check, when it is run.
(module+ main
  (main))
