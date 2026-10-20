#lang racket/base
;; One job: the command table — one name, one function. Each function
;; takes the session and the words of the typed line, and answers whether
;; the session goes on and the line of text to print. What a typed line
;; means is the meaning side's job (rule 09); the text itself belongs to
;; the hot path, which holds the state.
;;
;; The order of this file is the order Racket reads it: every name is
;; defined before anything that uses it at load time, so the table can
;; name the handlers and the names can be sorted.

(require racket/list
         racket/path
         racket/string
         "../join/protocol.rkt"
         "../join/hot-path.rkt"
         "../journal/replay.rkt")

;; session is the state of one editing session: the file being edited and
;; the journal that holds the work not saved yet.
(struct session (file journal) #:transparent)

;; name<? orders two names, whether they are symbols or strings: the table
;; of commands is keyed by strings and the answers come back keyed by
;; symbols, and both must read in the same order.
(define (name<? a b)
  (string<? (if (symbol? a) (symbol->string a) a)
            (if (symbol? b) (symbol->string b) b)))

;; command-insert puts the rest of the line into the text. The text is
;; not written to the file yet: the journal holds it until a save.
(define (command-insert session words)
  (cons #t
        (answer-line
         (ask session "insert" (hasheq 'text (string-join words " "))))))

;; command-save writes the text to the file and empties the journal: the
;; work is in the file now.
(define (command-save session words)
  (cons #t (answer-line (ask session "save" (hasheq)))))

;; command-show answers the text as it stands: the file with the journal's
;; unsaved edits on top.
(define (command-show session words)
  (cons #t (answer-line (ask session "show" (hasheq)))))

;; command-journal answers the journal's records: every edit, in order.
(define (command-journal session words)
  (cons #t (answer-line (ask session "journal" (hasheq)))))

;; command-help answers the names in the table.
(define (command-help session words)
  (cons #t (string-join command-names ", ")))

;; command-quit ends the session: the answer says goodbye and the go-on
;; flag says no.
(define (command-quit session words)
  (cons #f "bye"))

;; command-replay rebuilds the state after a crash and reports what is
;; waiting: the counts and the journal's records. The text itself is what
;; the show command answers.
(define (command-replay session words)
  (cons #t
        (replay-report
         (replay-state (session-file session) (session-journal session)))))

;; commands is the table: one name, one function. The keys are compared
;; as text, so a name typed on the keyboard finds its function.
(define commands
  (hash "insert" command-insert
        "save" command-save
        "show" command-show
        "journal" command-journal
        "replay" command-replay
        "help" command-help
        "quit" command-quit))

;; command-names answers the names in the table, in a fixed order.
(define command-names
  (sort (hash-keys commands) name<?))

;; words-of splits one typed line into its words.
(define (words-of line)
  (filter (lambda (word) (not (string=? word ""))) (string-split line " ")))

;; run-command runs one typed line and answers whether the session goes
;; on, and the line of text to print. A line with no words says nothing
;; and changes nothing.
(define (run-command session line)
  (define words (words-of line))
  (if (null? words)
      (cons #t "")
      (let ([name (car words)] [rest (cdr words)])
        (define handler (hash-ref commands name #f))
        (if handler
            (handler session rest)
            (cons #t (format "there is no command named ~a; ask for one of: ~a"
                             name (string-join command-names ", ")))))))

;; ask sends one request to the hot path for this session and answers the
;; response. The file and the journal are added to every request: the hot
;; path holds no session of its own.
(define (ask session op args)
  (ask-hot op (hash-set (hash-set args 'file (path->string (session-file session)))
                         'journal (path->string (session-journal session)))))

;; answer-line turns one answer from the hot path into one line of text,
;; with the names in a fixed order, so two answers read the same way.
(define (answer-line answer)
  (define data (response-data answer))
  (if (response-ok answer)
      (string-join
       (for/list ([key (sort (hash-keys data) name<?)])
         (format "~a=~a" key (hash-ref data key)))
       " ")
      (format "FAIL ~a" (hash-ref data 'what "the hot path refused the request"))))

;; make-session makes the session of one file: the file itself and the
;; journal that holds the work that is not saved yet. Nothing else is kept,
;; so the session is the only thing that carries the state between commands.
(define (make-session file journal)
  (session file journal))

;; The command table, for every area above this one.
(provide session
         make-session
         session-file
         session-journal
         run-command
         command-names
         answer-line)
