#lang racket/base
;; One job: the command table — one name, one function; a command reads the
;; document it was given, says what it found, and hands back the exit code a
;; shell may trust.
;; Registered in plan/package-tree.org (entry/dispatch.rkt). Lands with TODO
;; item 3; =check= lands with it, =literate= and =send= with TODO item 6 (build
;; step 5, literate code).
;;
;; The table is closed: a name nobody registered is refused here, so a command
;; cannot be added by accident. Two of the three commands only read. =check=
;; reads a parse-tree document and reports what is wrong with it; =literate=
;; reads a document's chunk graph and reports what is wrong with it and in what
;; order its chunks would be sent. =send= is the only command here that writes,
;; and it writes only what a plan step carries into a target the document
;; declared.
;;
;; The exit codes are three and each means exactly one thing.
;; diagnostics/report.rkt already promises a reader this table by name, so no
;; code is added here and no command writes a number of its own:
;;
;;   0  exit-clean    the command finished and there was nothing to report.
;;   1  exit-findings the document holds something the command names — an
;;                    error in the parse tree, or a finding in the chunk graph
;;                    — and nothing was written.
;;   2  exit-refused  the run was refused before it began: no document named,
;;                    no document at that path, or a command name nobody
;;                    registered. Nothing was written.
;;
;; =check= found its findings and its diagnosis through diagnostics/ with TODO
;; item 5; before that it read the error nodes itself and printed a shape of
;; its own, which is what the diagnostics area exists to end.

(require racket/file
         racket/list
         racket/port
         "../errors/raise.rkt"
         "../data/aiu-text.rkt"
         "../data/json.rkt"
         "../diagnostics/collect.rkt"
         "../diagnostics/report.rkt"
         "../generation/plan.rkt"
         "../generation/write.rkt"
         "../literate/chunks.rkt"
         "../literate/scan.rkt"
         "../literate/skip-journal.rkt"
         "../narration/narration.rkt"
         "../narration/print-console.rkt"
         "../narration/wait-door.rkt"
         "../model/outline.rkt")

(provide check literate send-chunks json from-json
         commands command-names command-for run)


;; The three exit codes, named once. A command hands one of these back to run,
;; run hands it to cli.rkt, and cli.rkt makes it the process exit code.
(define exit-clean 0)
(define exit-findings 1)
(define exit-refused 2)


;; check reads a parse-tree-document text and reports every error in it. It
;; returns the exit code: 0 when the document holds no error, 1 when it holds at
;; least one. Every line it prints names the file, the line, what is wrong and
;; what to do — the four things the error is required to carry.
(define (check args)
  (define path (first args))
  (cond
    [(or (not path) (string=? path ""))
     (print-line "check: name one document to read")
     2]
    [else
     ;; The document is read here, not in cli.rkt: dispatch is the command and
     ;; owns what a command needs; cli.rkt only reads argv. Reading it here also
     ;; keeps the two modules from requiring each other.
     (unless (file-exists? path)
       (print-line (format "check: no such file: ~a" path))
       (exit 2))
     ;; Read the file as text. file->string returns a string even with
     ;; #:mode 'binary on this build, so the mode keyword is kept and the result
     ;; is used as the string it is; no bytes->string/utf-8 conversion is
     ;; applied, because there are no bytes to convert.
     (define text (file->string path #:mode 'binary))
     (define o (read-outline text))
     (define file-name (or (outline-file o) path))
     ;; The tree is walked by diagnostics/collect.rkt and rendered by
     ;; diagnostics/report.rkt, which prints through errors/render.rkt — the
     ;; only printer of an error in the package. This command adds no shape
     ;; of its own: it reads the report and decides what to exit with. The
     ;; page is #f, because a parse-tree-document carries byte offsets and no
     ;; page; with no page no column can be counted, and every finding says
     ;; its column is unknown rather than naming a wrong one.
     (define report (build-report file-name (collect-findings #f o)))
     (define body (report-text report))
     ;; The exit code comes from the report, not from a count read here, so one
     ;; place decides what a finding is worth to the shell.
     (define code (report-exit-code report))
     (unless (string=? body "") (print-line body))
     (if (= code 0)
         (begin
           (print-line (format "~a: no errors in the parse tree document" file-name))
           code)
         (begin
           (print-line (format "~a: ~a finding(s); the document is not clean"
                               file-name (report-count report)))
           code))]))

;; literate reads a document's chunk graph and reports it: every finding, with
;; what is wrong and what to do, and the order the chunks may be sent in.
;;
;; It writes nothing at all — no target, no store entry, no lock — and it never
;; asks for the store path, because asking for that path creates the run's state
;; directory, and a write hidden inside a read is the one thing a read-only
;; command may not do.
;;
;; The findings and the order are scan.rkt's answers, not this file's. Every
;; finding was already said out loud by scan-chunks as it was found, through
;; the one printer, carrying what is wrong and what to do; this command adds no
;; second wording of a finding. The order is asked for only when the graph is
;; clean, because chunks that wait on each other have no order to ask for and
;; chunk-send-order refuses to invent one that happens to work today.
(define (literate args)
  (define who "literate")
  (define path (first args))
  (cond
    [(or (not path) (string=? path ""))
     (refuse who "name one document to read" (run-with who))]
    [(not (file-exists? path))
     (refuse who (format "there is no document at ~a" path)
             "check the path you were given, or write the document first")]
    [else
     ;; The page is read once and held twice over: read-outline builds the tree
     ;; out of it and read-chunk-graph reads the chunk bodies out of the same
     ;; text, so the lines a chunk came from are the lines the tree named.
     (define page (document-text path))
     (define graph (read-chunk-graph (read-outline page) page))
     (define file-name (or (chunk-graph-file graph) path))
     (define findings (scan-chunks graph))
     (cond
       [(null? findings)
        ;; One name per line, read down a screen: a list printed by Racket
        ;; reads as "(a b c)", which is not an order anybody can act on.
        (define order (chunk-send-order graph))
        (say-step (format "the order to send ~a in" (length order))
                  "each chunk comes after every chunk it depends on, so no chunk is sent against text that has not been sent yet; this command sent none of them")
        (for-each (lambda (n) (print-line (format "  ~a" n))) order)
        (say-note who
                  (format "~a: ~a chunk(s), no findings, and nothing was written"
                          file-name (length order)))
        exit-clean]
       [else
        (say-note who
                  (format "~a: the chunk graph holds ~a finding(s); the lines above name each one and what to do, so fix them and run literate again"
                          file-name (length findings)))
        exit-findings])]))


;; send-chunks is the send command: it reads a document's chunk graph, builds
;; the whole run as a plan, prints that plan, and then carries it out.
;;
;; The order of those three acts is the whole discipline. Nothing is planned
;; until the graph is clean, because a chunk that waits on a chunk no document
;; carries has no hash worth sending. Nothing is written until the plan has been
;; printed, so a reader has seen every file that is about to change before the
;; first of them changes.
;;
;; A chunk whose content hash is already on disk is not written again:
;; decide-skip made that decision while the plan was built and said the sentence
;; aloud, and a skip that writes anyway is not a skip. A chunk that loads in
;; place is not written either, and the plan already said why. What is left is
;; exactly what changed, and write.rkt is the only place that writes a byte of
;; it — every disk touch it makes is wrapped in the same wait door, from the
;; store directory opened here to the last store entry recorded.
;;
;; The command name is send and the function is send-chunks, because
;; racket/base already has a send, and a reader must never have to ask which of
;; the two a line in this file means.
(define (send-chunks args)
  (define who "send")
  (define path (first args))
  (cond
    [(or (not path) (string=? path ""))
     (refuse who "name one document to send" (run-with who))]
    [(not (file-exists? path))
     (refuse who (format "there is no document at ~a" path)
             "check the path you were given, or write the document first")]
    [else
     (define page (document-text path))
     (define graph (read-chunk-graph (read-outline page) page))
     (define file-name (or (chunk-graph-file graph) path))
     (define findings (scan-chunks graph))
     (cond
       [(pair? findings)
        (say-note who
                  (format "~a: the chunk graph holds ~a finding(s); the lines above name each one and what to do, so fix them and run send again. Nothing was planned and nothing was written"
                          file-name (length findings)))
        exit-findings]
       [else
        ;; The store is where the last run of this document recorded what it
        ;; sent, and asking for its path creates the directory that holds it:
        ;; the first write of this command, and the wait door says why before it
        ;; blocks. The store is named by the hash of the document's own path, so
        ;; two documents never share one.
        (define store
          (with-wait (format "opening the generation store for ~a" path)
                     "the store is where the last run of this document recorded what it already sent, and the same content hash found there is a chunk this run will not send again"
            (store-path path)))
        (define steps (build-plan graph store))
        (print-plan steps)
        (send-plans path steps store)
        exit-clean])]))


;; document-text reads the named document as text. The read is a block on a
;; disk that may be slow, full or gone, so it says what it is about to do and
;; why before it blocks and again when it is through.
;;
;; check does not read through here and is left exactly as it was: its lines are
;; the ones diagnostics/report.rkt promises a reader, and a read that grew a wait
;; line would change what a reader of a clean document is shown.
(define (document-text path)
  (with-wait (format "reading ~a" path)
             "the document may sit on a disk that is slow or gone, and a read that blocks without saying so is the failure this package exists to prevent"
    (file->string path #:mode 'binary)))

;; refuse prints one refusal and hands back an exit code. Every refusal a
;; command makes carries the same three parts: who refuses (the command name),
;; what is wrong, and what to do next. It is printed rather than raised, because
;; what calls a command reads an exit code, and an exception that leaves the
;; program prints a stack trace where this package promises one line
;; (errors/render.rkt). The areas below raise through raise-err; this does not
;; re-implement their door, and it does not re-word what they say.
(define (refuse who what what-to-do)
  (print-line (format "~a: ~a; what to do: ~a" who what what-to-do))
  exit-refused)

;; run-with is the what-to-do shared by every command refused for want of an
;; argument: the shape of an invocation, and the names that do exist.
(define (run-with who)
  (format "run `notation ~a <document>`, or one of the other commands: ~a"
          who (command-names)))


;; json turns a page into JSON: the structured value the Nushell side and any
;; other tool wants, instead of text.
;;
;; The parse tree comes from the Rust binary, because the Rust crate is the
;; parser; the binary is named by the environment variable AIU_NOTATION_BIN,
;; and tools/aiu.nu sets it. When it is not set the command refuses and says
;; what to do, because a command that guesses a path is a command that fails
;; in a way nobody can act on.
(define (json args)
  (define who "json")
  (define path (first args))
  (cond
    [(or (not path) (string=? path ""))
     (refuse who "name one page to read" (run-with who))]
    [(not (file-exists? path))
     (refuse who (format "there is no page at ~a" path)
             "check the path you were given, or write the page first")]
    [else
     (define bin (or (getenv "AIU_NOTATION_BIN") ""))
     (if (string=? bin "")
         (refuse who "the notation binary is not named, and the page cannot be read without it"
                 "set AIU_NOTATION_BIN to the notation binary, or use tools/aiu.nu, which sets it for you")
         (let* ([document (run-notation bin path)]
                [o (read-outline document)]
                [page (file->bytes path)]
                [value (document->json o page)])
           (print-line (json->text value))
           exit-clean))]))

;; from-json turns a JSON file into a .aiu page, written to the standard
;; output. The other way round of the json command, and the way a JSON file
;; becomes a page a person can read.
(define (from-json args)
  (define who "from-json")
  (define path (first args))
  (cond
    [(or (not path) (string=? path ""))
     (refuse who "name one JSON file to read" (run-with who))]
    [(not (file-exists? path))
     (refuse who (format "there is no file at ~a" path)
             "check the path you were given, or write the file first")]
    [else
     (define value (parse-json (file->string path #:mode 'binary)))
     (define blocks (json->blocks value))
     (print-line (blocks->aiu-text blocks))
     exit-clean]))

;; run-notation runs the Rust binary over a page and gives back the parse-tree
;; document it printed. The binary's own output is what is wanted, so it is
;; captured instead of being printed, and the binary's complaints go to
;; nowhere rather than into the JSON.
(define (run-notation bin path)
  (define out (open-output-string))
  (parameterize ([current-output-port out]
                 [current-error-port (open-output-nowhere)])
    (system* bin "parse" path))
  (get-output-string out))


;; The one table: one name, one function. Adding a command is a decision for
;; the owner, so the table says what exists rather than what might. The name is
;; what a reader types and the function is what this file calls it.
(define commands
  (list (list "check" check)
        (list "literate" literate)
        (list "send" send-chunks)
        (list "json" json)
        (list "from-json" from-json)))

;; command-names lists the registered command names, for --list and for the
;; refusal message.
(define (command-names)
  (map first commands))

;; command-for returns the function for a name, or #f.
(define (command-for name)
  (for/first ([c (in-list commands)] #:when (string=? (car c) name)) (cadr c)))

;; run dispatches one argv list to one command and returns its exit code. An
;; unknown command is refused through the same door every other refusal uses,
;; carrying the same three parts — who, what, what to do — and the names that do
;; exist, because a usage string a reader cannot act on is a refusal with two
;; of its three parts missing. It is never treated as a success.
(define (run argv)
  (cond
    [(null? argv)
     (refuse "notation" "name a command to run" (names-to-run))]
    [else
     (define name (car argv))
     (define args (if (null? (cdr argv)) '() (cdr argv)))
     (define fn (command-for name))
     (cond
       [fn (fn args)]
       [else
        (refuse "notation" (format "there is no command named ~a" name)
                (names-to-run))])]))

;; names-to-run is the what-to-do the table itself speaks: the commands that
;; exist, written the way run-with writes them, so a reader is given the same
;; answer wherever they asked.
(define (names-to-run)
  (format "run one of the commands that exist: ~a" (command-names)))