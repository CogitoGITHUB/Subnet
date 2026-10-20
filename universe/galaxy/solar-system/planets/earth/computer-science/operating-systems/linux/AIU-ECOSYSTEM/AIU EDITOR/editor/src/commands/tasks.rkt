#lang racket/base
;; One job: the task table and the runner — declare, list, run, sequence.
;; Registered in plan/package-tree.org; lands with TODO item 17.
;;
;; A task is a plain function on the meaning side (rule 09): it takes the
;; session and the list of string arguments, and answers one line of text.
;; Its doc line is the comment line above its own definition, so the list
;; and the help come from the source and never from a second list.
;;
;; A task that acts honours the dry-run scope: when that scope is open
;; the task prints what it would do and changes nothing, so a run can be
;; tried without touching the file.
;;
;; A task may call other tasks, and several runs in one invocation are a
;; sequence: they run in the order they were given.

(require racket/file
         racket/list
         racket/runtime-path
         racket/string
         "../narration/print-console.rkt"
         "../commands/commands.rkt")

;; tasks-source is this file: the doc line of a task is the comment above
;; its definition, and the comment is in this file.
(define-runtime-path tasks-source "tasks.rkt")

;; dry-run? is the scope a task asks before it acts. When it is on, the
;; task prints what it would do and changes nothing.
(define dry-run? (make-parameter #f))

;; source-lines are the lines of this file, read once.
(define source-lines (file->lines tasks-source))

;; task-say prints the words it was given as one line, and changes
;; nothing. The function is named for what it is, so it never collides with
;; the narration's say: the task's NAME is "say", and the function that
;; runs it is task-say.
(define (task-say session args)
  (string-join args " "))

;; insert puts the words into the buffer and journals the edit. In the
;; dry-run scope it prints what it would do and changes nothing.
(define (insert session args)
  (define text (string-join args " "))
  (if (dry-run?)
      (format "would insert: ~a" text)
      (answer-line (ask session "insert" (hasheq 'text text)))))

;; tasks is the table: one name, one function. The names are the names of
;; the tasks, and nothing else is a task.
(define tasks
  (hash "say" task-say
        "insert" insert))

;; task-names answers the names in the table, in a fixed order.
(define task-names
  (sort (hash-keys tasks) string<?))

;; definition-index answers the place of the definition of a name in this
;; file, or nothing when the file holds no such definition.
(define (definition-index name)
  (define wanted (string-append "(define (" name " "))
  (let loop ([lines source-lines] [at 0])
    (cond
      [(null? lines) #f]
      [(string-prefix? (car lines) wanted) at]
      [else (loop (cdr lines) (+ at 1))])))

;; doc-line-of answers the doc line of a task: the comment block directly
;; above its definition, with the two semicolons taken off and the lines
;; joined by a space, so a doc line that wraps reads as one line. It
;; answers nothing when the source holds no comment above the definition.
(define (doc-line-of name)
  (define index (definition-index name))
  (and index
       (let loop ([at (- index 1)] [parts '()])
         (cond
           [(< at 0) (if (null? parts) #f (string-join parts " "))]
           [(string-prefix? (list-ref source-lines at) ";;")
            (loop (- at 1)
                  (cons (string-trim (substring (list-ref source-lines at) 2)) parts))]
           [else (if (null? parts) #f (string-join parts " "))]))))

;; task-lines answers one line per task: the name, then the doc line, so
;; the list and the help read the same way every time.
(define (task-lines)
  (for/list ([name (in-list task-names)])
    (format "~a — ~a" name (or (doc-line-of name) "no doc line"))))

;; run-task runs one task and answers the line it printed. A name the
;; table does not hold is refused by name, never guessed at.
(define (run-task session name args)
  (define task (hash-ref tasks name #f))
  (if task
      (task session args)
      (format "there is no task named ~a; ask for one of: ~a"
              name (string-join task-names ", "))))

;; run-tasks runs the tasks of one invocation in the order they were
;; given, and answers one line per task. It is the sequence: the first
;; run may change what the second one sees.
(define (run-tasks session groups)
  (for/list ([group (in-list groups)])
    (run-task session (car group) (cdr group))))

;; The task table and the runner, for the entry above them.
(provide dry-run?
         task-say
         insert
         tasks
         task-names
         task-lines
         doc-line-of
         run-task
         run-tasks)
