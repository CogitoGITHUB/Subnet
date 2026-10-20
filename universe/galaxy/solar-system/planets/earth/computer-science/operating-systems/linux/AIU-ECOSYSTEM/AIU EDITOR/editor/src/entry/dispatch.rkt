#lang racket/base
;; One job: the argv dispatch — one name, one function. The name is the
;; verb the user typed; the function is what it does. The session it runs
;; reads one command per line from the standard input, and every answer is
;; printed in the one printer, so the run reads in one voice.
;;
;; The order of this file is the order Racket reads it: the table comes
;; after the functions it names, so it can be built when the file loads.

(require racket/list
         racket/path
         racket/port
         racket/string
         "../narration/print-console.rkt"
         "../narration/narration.rkt"
         "../machine/directories.rkt"
         "../commands/commands.rkt"
         "../commands/tasks.rkt"
         "../devloop/bake.rkt"
         "../devloop/last-good.rkt"
         "../dashboard/dashboard.rkt"
         "../routes/keyboard.rkt"
         "../routes/keymaps.rkt"
         "../checkpoint/checkpoint.rkt"
         "../checkpoint/rollback.rkt"
         "../machine/stop-switch.rkt"
         "../send/adapter.rkt"
         "../send/bundle.rkt"
         "../send/send.rkt"
         "../routes/routes.rkt"
         "../join/hot-path.rkt"
         "live.rkt")

;; input-is-a-terminal? answers whether the standard input is a
;; terminal, and not a pipe. A terminal means the live session: the keys
;; are read one at a time. A pipe means the scripted session: one
;; command per line, so every proof that drives the editor with a pipe
;; keeps working.
(define (input-is-a-terminal?)
  (terminal-port? (current-input-port)))

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
  (if (input-is-a-terminal?)
      (live-session file journal)
      (begin
        (open-run "the editor" (format "editing ~a" file))
        (print-line (answer-line (ask-hot "open" (hasheq 'file (path->string file)
                                                       'journal (path->string journal)))))
        (let loop ()
          (define line (read-line (current-input-port)))
          (unless (eof-object? line)
            (define answer (run-command session line))
            (define text (cdr answer))
            (unless (string=? text "") (print-line text))
            (when (car answer) (loop)))))))

;; routes-walk runs the routing walk and prints one line per key: which
;; layer saw the key and what it meant there. The keys are the ones given
;; on the command line, or every key the editor binds when none are
;; given, plus the reserved prefix, so the walk always shows the whole
;; shape. The program-claims are the keys the focused program wants; they
;; are given as the words before the layer.
(define (routes-walk args)
  (define layer (if (null? args) "visual" (car args)))
  (define claims (if (null? args) '() (cdr args)))
  (define keys (if (null? args)
                   (append (list reserved-prefix)
                           (map car (keys-of layer)))
                   (list reserved-prefix)))
  (print-line (format "layer: ~a  program claims: ~a  reserved prefix: ~a"
                       layer
                       (if (null? claims) "none" (string-join claims " "))
                       reserved-prefix))
  (for-each (lambda (answer) (print-line (route-line answer)))
            (route-walk keys claims layer)))

;; tasks-verb answers the task table: one line per task, the name and
;; the doc line of the task, so the list and the help read the same way.
(define (tasks-verb args)
  (if (null? args)
      (for-each print-line (task-lines))
      (print-line "the editor: tasks takes no arguments")))

;; task-verb runs tasks against a file. The first word is the file, and
;; after it come the runs: a task name and the words that are its
;; arguments. A "--" between two runs starts the next one, so several
;; runs in one invocation are a sequence and they run in the order they
;; were given. A "--dry-run" word opens the dry-run scope, where a task
;; that acts prints what it would do and changes nothing.
(define (task-verb args)
  (cond
    [(null? args)
     (print-line "the editor: task needs a file")]
    [else
     (define dry (member "--dry-run" args))
     (define words (if dry (remove "--dry-run" args) args))
     (define file (path->complete-path (car words)))
     (define session (make-session file (journal-path-for file)))
     (define groups (split-runs (cdr words)))
     (define answers
       (parameterize ([dry-run? (and dry #t)])
         (run-tasks session groups)))
     (for-each print-line answers)]))

;; split-runs splits the words of an invocation into the runs of a
;; sequence. A "--" starts the next run; the words before it are the
;; name of the first task and its arguments. The runs come back in the
;; order they were given.
(define (split-runs words)
  (let loop ([rest words] [current '()] [runs '()])
    (cond
      [(null? rest)
       (if (null? current) (reverse runs) (reverse (cons (reverse current) runs)))]
      [(string=? (car rest) "--")
       (loop (cdr rest) '() (if (null? current) runs (cons (reverse current) runs)))]
      [else (loop (cdr rest) (cons (car rest) current) runs)])))

;; keys-verb answers what the bytes of a key are and what they mean.
;; The bytes are given as hex, because a key may be any byte at all: the
;; walk answers the name of each key, the layer that saw it, and the
;; command it runs there. The layer may be named after the bytes, and it
;; is the visual layer without one.
(define (keys-verb args)
  (define layer (if (null? args) "visual" (car args)))
  (define hexes (if (null? args) '() (cdr args)))
  (for-each
   (lambda (hex)
     (define names (key-names (hex->bytes hex)))
     (if (null? names)
         (print-line (format "~a -> no key" hex))
         (for-each
          (lambda (name)
            (define answer (route-of-key name '() layer))
            (print-line (format "~a -> ~a ~a"
                                name
                                (first answer)
                                (if (string=? (second answer) "") "-" (second answer)))))
          names)))
   hexes))

;; dashboard-verb draws the dashboard and prints it, one line per row of
;; the screen. The file is the one being edited; without a file the
;; dashboard shows the editor alone.
(define (dashboard-verb args)
  (define file (if (null? args) "" (car args)))
  (define path (path->complete-path (if (string=? file "") "untitled" file)))
  (define journal (journal-path-for path))
  (define state (session-state (path->string path) (path->string journal)))
  (for-each print-line (draw-dashboard the-pieces state)))

;; baked-good? asks whether the baked module holds the tables it was
;; given: the bake is good when what it wrote is what it was given.
(define (baked-good? path)
  (with-handlers ([exn:fail? (lambda (why) #f)])
    (define tables (dynamic-require (make-resolved-module-path path) 'baked-tables))
    (equal? tables keymaps)))

;; bake-verb bakes the config: the tables become first-class defaults in
;; a generated module, the bake checks the result, and the last good is
;; kept only when the check says yes. A bake that is not good never
;; ships.
(define (bake-verb args)
  (define result (bake keymaps baked-good?))
  (define path (car result))
  (define good (cadr result))
  (print-line (format "baked: ~a" path))
  (if good
      (print-line (format "the bake is good and is now the last good: ~a" (last-good)))
      (print-line (format "the bake is NOT good; the last good stays: ~a"
                          (or (last-good) "there is none")))))

;; send-verb shows what a send would carry: the bundle, line by line, and
;; then the adapter's answer. The file is the one being edited, the target
;; is the named agent, and the why is the rest of the words. A send
;; without a why is refused.
(define (send-verb args)
  (define file (if (null? args) "" (car args)))
  (define rest (if (null? args) '() (cdr args)))
  (define target (if (null? rest) "opencode" (car rest)))
  (define why (if (null? rest) "" (string-join (cdr rest) " ")))
  (define path (path->complete-path (if (string=? file "") "untitled" file)))
  (define session (make-session path (journal-path-for path)))
  (define the-bundle
    (make-bundle "aiu-editor" "aiu-ecosystem" target
                 (selection-text session)
                 (path->string path)
                 (the-point session)
                 #f
                 why))
  (cond
    [(not the-bundle)
     (print-line "a send needs a why: say what the sender was doing")]
    [else
     (for-each print-line (bundle-lines the-bundle))
     (let ([answer (deliver opencode-adapter the-bundle)])
       (if (car answer)
           (print-line (format "sent to ~a" target))
           (print-line (format "the send was refused: ~a — ~a"
                               (hash-ref (cdr answer) 'what)
                               (hash-ref (cdr answer) 'what_to_do)))))])) 

;; checkpoint-verb makes a checkpoint of the tree: the state the tree is
;; put back to when an agent does something the human did not want. The
;; words are the why.
(define (checkpoint-verb args)
  (define root (if (null? args) "." (car args)))
  (define why (string-join (if (null? args) '() (cdr args)) " "))
  (define made (checkpoint (path->complete-path root) why))
  (if made
      (print-line (format "checkpoint: ~a" made))
      (print-line "a checkpoint needs a why: say what the agent was about to do")))

;; rollback-verb puts the tree back to a checkpoint.
(define (rollback-verb args)
  (define root (if (null? args) "." (car args)))
  (define commit (if (null? args) "" (cadr args)))
  (define answer (rollback (path->complete-path root) commit))
  (if (car answer)
      (print-line (format "the tree is back at ~a" (car answer)))
      (print-line (format "the rollback was refused: ~a" (cdr answer)))))

;; stop-verb throws or clears the stop switch: while it is thrown, every
;; agent session for this project stops.
(define (stop-verb args)
  (define what (if (null? args) "stop" (car args)))
  (cond
    [(string=? what "stop")
     (throw-switch)
     (print-line "the stop switch is thrown: every agent session for this project stops")]
    [(string=? what "start")
     (clear-switch)
     (print-line "the stop switch is cleared: the agent sessions may run again")]
    [else
     (print-line (format "the stop switch is ~a" (if (stopped?) "thrown" "clear")))]))

;; edit-file opens the file the user named and runs the editing session.
(define (edit-file args)
  (if (null? args)
      (print-line "the editor: edit needs a file")
      (edit-session (car args))))

;; commands is the table: one name, one function.
(define commands
  (hash "edit" edit-file
        "routes" routes-walk
        "task" task-verb
        "tasks" tasks-verb
        "keys" keys-verb
        "dashboard" dashboard-verb
        "bake" bake-verb
        "send" send-verb
        "checkpoint" checkpoint-verb
        "rollback" rollback-verb
        "stop" stop-verb))

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
