#lang racket/base
;; One job: argv to a command — one parser, one dispatch.
;; Registered in plan/package-tree.org (entry/cli.rkt). Lands with TODO item 3.
;;
;; This is the only place that reads argv and the only place that reads a file
;; for the commands. It parses the argv list, hands it to dispatch.rkt, and
;; turns the returned exit code into the process exit code. It decides nothing
;; about what a command means.

(require racket/file
         "dispatch.rkt")

;; cli-read-file reads a document as text and refuses a file it cannot read,
;; naming the file. The bytes are read as written: no line ending is changed,
;; so the offsets in the document still point at the same bytes.
(define (cli-read-file path)
  (unless (file-exists? path)
    (error 'cli (format "check: no such file: ~a" path)))
  (file->string path #:mode 'text))

;; cli-args turns the process arguments into one list: the command name and its
;; arguments, in that order. It drops the executable name and nothing else.
(define (cli-args argv)
  (if (null? argv) '() (cdr argv)))

;; cli-main is the whole program: parse, dispatch, exit with the code that came
;; back. A code of 0 means the command found nothing wrong; anything else is a
;; refusal or a failure and must not be reported as success.
(define (cli-main argv)
  (exit (run (cli-args argv))))

(module+ main
  (cli-main (vector->list (current-command-line-arguments))))