#lang racket/base
;; One job: argv to a command — one parser, one dispatch.
;; Registered in plan/package-tree.org (entry/cli.rkt). Lands with TODO item 3.
;;
;; This is the only place that reads argv and the only place that reads a file
;; for the commands. It parses the argv list, hands it to dispatch.rkt, and
;; turns the returned exit code into the process exit code. It decides nothing
;; about what a command means.

(require "dispatch.rkt")

(provide cli-args cli-main)


;; cli-args turns the process arguments into one list: the command name and its
;; arguments, in that order. Nothing is dropped. Racket hands a script the
;; arguments after the script name, so "racket cli.rkt check page" arrives as
;; ("check" "page") — the command is already first.
(define (cli-args argv)
  argv)

;; cli-main is the whole program: parse, dispatch, exit with the code that came
;; back. A code of 0 means the command found nothing wrong; anything else is a
;; refusal or a failure and must not be reported as success.
(define (cli-main argv)
  (exit (run (cli-args argv))))

;; The main part: it reads the command line and hands the command and
;; its file to the dispatcher.
;; The program entry point: running this file as a script turns the process
;; arguments into the command call and exits with whatever it answers.
(module+ main
  (cli-main (vector->list (current-command-line-arguments))))