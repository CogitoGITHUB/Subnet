#lang racket/base
;; One job: argv to a command — one parser, one dispatch. The verb is the
;; first argument, the rest are the arguments of the verb, and the
;; dispatch holds what each verb does.
;;
;; Usage: racket cli.rkt edit FILE

(require "dispatch.rkt"
         "../devloop/start.rkt"
         "../narration/print-console.rkt")

;; main parses the arguments and hands them to the dispatch.
(define (main)
  (define args (vector->list (current-command-line-arguments)))
  (cond
    [(null? args) (usage "no command was given")]
    [else
     (define verb (car args))
     (if (command-known? verb)
         (begin
           ;; the measured start is printed with the first answer: it is
           ;; information, not a gate (rule 02)
           (print-start)
           (run-verb verb (cdr args)))
         (usage (format "there is no command named ~a" verb)))]))

;; usage says how the program is called, and stops.
(define (usage why)
  (print-line (format "the editor: ~a" why))
  (print-line "usage: racket cli.rkt edit FILE | routes | tasks | task | keys | dashboard | bake")
  (exit 2))

;; The parser, for the outside world.
(module+ main
  (main))
