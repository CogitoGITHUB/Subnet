#lang racket/base
;; One job: the command table — one name, one function; =check= lists every
;; error with its line number and exits non-zero.
;; Registered in plan/package-tree.org (entry/dispatch.rkt). Lands with TODO
;; item 3.
;;
;; The table is closed: a name nobody registered is refused here, so a command
;; cannot be added by accident. Reading is free; this only reads a document and
;; reports what is wrong with it. Nothing here writes.
;;
;; =check= found its findings and its diagnosis through diagnostics/ with TODO
;; item 5; before that it read the error nodes itself and printed a shape of
;; its own, which is what the diagnostics area exists to end.

(require racket/file
         racket/list
         "../errors/raise.rkt"
         "../diagnostics/collect.rkt"
         "../diagnostics/report.rkt"
         "../narration/print-console.rkt"
         "../model/outline.rkt")

(provide check commands command-names command-for run)


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

;; The one table: one name, one function. Adding a command is a decision for
;; the owner, so the table says what exists rather than what might.
(define commands
  (list (list "check" check)))

;; command-names lists the registered command names, for --list and for the
;; refusal message.
(define (command-names)
  (map first commands))

;; command-for returns the function for a name, or #f.
(define (command-for name)
  (for/first ([c (in-list commands)] #:when (string=? (car c) name)) (cadr c)))

;; run dispatches one argv list to one command and returns its exit code. An
;; unknown command is refused with the names that do exist; it is never
;; treated as a success.
(define (run argv)
  (cond
    [(null? argv)
     (print-line (format "notation: name a command; the commands are ~a" (command-names)))
     2]
    [else
     (define name (car argv))
     (define args (if (null? (cdr argv)) '() (cdr argv)))
     (define fn (command-for name))
     (cond
       [fn (fn args)]
       [else
        (print-line (format "notation: no command named ~a; the commands are ~a" name (command-names)))
        2])]))