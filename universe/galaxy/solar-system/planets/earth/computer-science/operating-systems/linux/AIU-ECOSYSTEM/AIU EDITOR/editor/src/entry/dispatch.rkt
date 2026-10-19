#lang racket/base
;; One job: the argv dispatch — one name, one function. The name is the
;; verb the user typed; the function is what it does. The session it runs
;; reads one command per line from the standard input, and every answer is
;; printed in the one printer, so the run reads in one voice.
;;
;; The order of this file is the order Racket reads it: the table comes
;; after the functions it names, so it can be built when the file loads.

(require racket/path
         racket/port
         "../narration/print-console.rkt"
         "../narration/narration.rkt"
         "../machine/directories.rkt"
         "../commands/commands.rkt"
         "../join/hot-path.rkt")

;; edit-session opens the file, then reads one command per line until the
;; session ends or the input ends. Every answer goes through the one
;; printer.
(define (edit-session path)
  (define file (path->complete-path path))
  (define journal (journal-path-for file))
  (define session (make-session file journal))
  ;; the journal's directory is made before the first edit: the hot path
  ;; writes there, and it must not have to create a directory to save work
  (ensure-dir (build-path (state-dir) "journal"))
  (open-run "the editor" (format "editing ~a" file))
  (print-line (answer-line (ask-hot "open" (hasheq 'file (path->string file)
                                                 'journal (path->string journal)))))
  (let loop ()
    (define line (read-line (current-input-port)))
    (unless (eof-object? line)
      (define answer (run-command session line))
      (define text (cdr answer))
      (unless (string=? text "") (print-line text))
      (when (car answer) (loop)))))

;; edit-file opens the file the user named and runs the editing session.
(define (edit-file args)
  (if (null? args)
      (print-line "the editor: edit needs a file")
      (edit-session (car args))))

;; commands is the table: one name, one function.
(define commands
  (hash "edit" edit-file))

;; command-known? answers whether the table holds the name.
(define (command-known? verb)
  (and (hash-has-key? commands verb) #t))

;; run-verb runs the verb with its arguments.
(define (run-verb verb args)
  (define handler (hash-ref commands verb #f))
  (if handler
      (handler args)
      (print-line (format "there is no command named ~a" verb))))

;; The argv dispatch, for the entry above it.
(provide commands
         command-known?
         run-verb)
