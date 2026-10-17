#lang racket/base
;; One job: the command table — one name, one function; =check= lists every
;; error with its line number and exits non-zero.
;; Registered in plan/package-tree.org (entry/dispatch.rkt). Lands with TODO
;; item 3.
;;
;; The table is closed: a name nobody registered is refused here, so a command
;; cannot be added by accident. Reading is free; this only reads a document and
;; reports what is wrong with it. Nothing here writes.

(require "../errors/raise.rkt"
         "../narration/print-console.rkt"
         "../model/outline.rkt"
         "../model/nodes.rkt"
         "cli.rkt")

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
     (define text (cli-read-file path))
     (define o (read-outline text))
     (define errors (outline-errors o))
     (define file-name (or (outline-file o) path))
     (for ([e (in-list errors)])
       (print-line (format "~a:~a: ~a: ~a; what to do: ~a"
                           file-name
                           (error-node-line e)
                           (error-node-kind e)
                           (error-node-what e)
                           (error-node-what-to-do e))))
     (if (null? errors)
         (begin
           (print-line (format "~a: no errors in the parse tree document" file-name))
           0)
         (begin
           (print-line (format "~a: ~a error(s); the document is not clean" file-name (length errors)))
           1))]))

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