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
         "../buffer/selection.rkt"
         "../join/protocol.rkt"
         "../join/hot-path.rkt"
         "../journal/replay.rkt")

;; session is the state of one editing session: the file being edited, the
;; journal that holds the work not saved yet, and the point — where the
;; cursor stands — and the selection, which is the region around the
;; point when a selection is on. The point and the selection are boxes,
;; because a command changes them.
(struct session (file journal point selection layer) #:transparent)

;; name<? orders two names, whether they are symbols or strings: the table
;; of commands is keyed by strings and the answers come back keyed by
;; symbols, and both must read in the same order.
(define (name<? a b)
  (string<? (if (symbol? a) (symbol->string a) a)
            (if (symbol? b) (symbol->string b) b)))

;; command-insert-words puts the rest of the line into the text at the
;; end of the buffer. The text is not written to the file yet: the
;; journal holds it until a save.
(define (command-insert-words session words)
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

;; command-move moves the cursor a way. The hot path holds the text, so
;; it is asked where the cursor goes.
(define (command-move session direction)
  (define answer
    (ask session "move" (hasheq 'at (number->string (the-point session))
                            'direction direction)))
  (if (response-ok answer)
      (begin
        (move-to session (string->number (hash-ref (response-data answer) 'at "0")))
        ;; in the select layer the cursor GROWS the region: that is what
        ;; a selection is, and the region is the buffer area's
        (when (string=? (the-layer session) "select")
          (set-box! (session-selection session)
                     (grow-region (the-selection session) (the-point session))))
        (cons #t (format "point=~a" (the-point session))))
      (cons #t "the cursor could not be moved")))

;; command-move-up moves the cursor up a line.
(define (command-move-up session words) (command-move session "up"))

;; command-move-down moves the cursor down a line.
(define (command-move-down session words) (command-move session "down"))

;; command-move-left moves the cursor left a character.
(define (command-move-left session words) (command-move session "left"))

;; command-move-right moves the cursor right a character.
(define (command-move-right session words) (command-move session "right"))

;; command-type puts text into the buffer where the cursor stands, and
;; journals the edit with the place it happened. This is the command
;; the keys of the insert layer run.
(define (command-type session words)
  (define text (string-join words " "))
  (define at (the-point session))
  (define answer
    (ask session "insert-at" (hasheq 'at (number->string at) 'text text)))
  (if (response-ok answer)
      (begin
        (move-to session (+ at (string-length text)))
        (cons #t (answer-line answer)))
      (cons #t "the text could not be inserted")))

;; command-delete takes one character out of the buffer, before the
;; cursor, and journals the edit.
(define (command-delete session words)
  (define at (the-point session))
  (define answer
    (ask session "delete-at" (hasheq 'at (number->string at) 'count "1")))
  (if (response-ok answer)
      (cons #t (answer-line answer))
      (cons #t "the text could not be deleted")))

;; command-select turns the selection on where the cursor stands, and
;; answers the text of the region.
(define (command-select session words)
  (select-from session (the-point session))
  (cons #t (selection-text session)))

;; command-send sends what is selected to the agent. The send area is ABOVE
;; this one, so this cannot call it: the send area puts its own command
;; here when it loads, and this is only the place it stands until then.
(define (command-send session words)
  (cons #t "the send action is not built yet: the agent boundary lands with the AI link"))

;; command-mode changes the layer the editor is in: the visual layer goes
;; to the write layer and the write layer goes back to the visual one.
;; The owner's key is a double space in the visual layer and a double tab
;; in the write layer, where a space is a typed space.
(define (command-mode session words)
  (define layer (the-layer session))
  (define next (if (string=? layer "write") "visual" "write"))
  (set-layer! session next)
  (cons #t (format "layer: ~a" next)))

;; command-visual-mode puts the editor in the visual layer, the general
;; mode.
(define (command-visual-mode session words)
  (set-layer! session "visual")
  (cons #t "layer: visual"))

;; command-write-mode puts the editor in the write layer, where the keys
;; are text.
(define (command-write-mode session words)
  (set-layer! session "write")
  (cons #t "layer: write"))

;; command-select-mode puts the editor in the select layer, where the
;; selected text is what the commands act on.
(define (command-select-mode session words)
  (set-layer! session "select")
  (cons #t "layer: select"))

;; commands is the table: one name, one function. The keys are compared
;; as text, so a name typed on the keyboard finds its function. The table
;; is MUTABLE: an area above this one may add its own command to it.
;; command-table is the table as data: one name and one function per
;; command.
(define command-table
  (hash "insert" command-insert-words
                           "type" command-type
                           "save" command-save
                           "show" command-show
                           "journal" command-journal
                           "replay" command-replay
                           "help" command-help
                           "quit" command-quit
                           "move-up" command-move-up
                           "move-down" command-move-down
                           "move-left" command-move-left
                           "move-right" command-move-right
                           "delete" command-delete
                           "select" command-select
                           "send" command-send
                           "mode" command-mode
                           "visual-mode" command-visual-mode
                           "write-mode" command-write-mode
                           "select-mode" command-select-mode))

;; commands is the table: one name, one function. The keys are compared
;; as text, so a name typed on the keyboard finds its function. The table
;; is MUTABLE: an area above this one may add its own command to it.
(define commands
  (let ([table (make-hash)])
    (for ([entry (in-list (hash->list command-table))])
      (hash-set! table (car entry) (cdr entry)))
    table))

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

;; make-session makes the session of one file: the file itself, the
;; journal that holds the work that is not saved yet, the point, the
;; selection and the layer the editor is in. Nothing else is kept, so the
;; session is the only thing that carries the state between commands.
(define (make-session file journal)
  (session file journal (box 0) (box #f) (box "visual")))

;; the-layer answers the layer the editor is in: "visual", "write" or
;; "select".
(define (the-layer session)
  (unbox (session-layer session)))

;; set-layer! puts the editor in a layer, and answers the layer.
(define (set-layer! session layer)
  (set-box! (session-layer session) layer)
  layer)

;; the-point answers where the cursor stands in this session.
(define (the-point session)
  (unbox (session-point session)))

;; move-to puts the cursor at a place, and answers the new place.
(define (move-to session at)
  (set-box! (session-point session) at)
  at)

;; the-selection answers the selection of this session, or nothing when
;; no selection is on.
(define (the-selection session)
  (unbox (session-selection session)))

;; select-from puts the start of the selection at a place, and turns the
;; selection on. The selection is a REGION: it runs from that place to
;; the cursor, and the region is the buffer area's.
(define (select-from session at)
  (set-box! (session-selection session) (start-region at))
  at)

;; select-off turns the selection off.
(define (select-off session)
  (set-box! (session-selection session) #f)
  #f)

;; selection-text answers the text of the selection, or the empty text
;; when there is no selection. The hot path holds the text, so it is
;; asked for the region.
(define (selection-text session)
  (define answer
    (region-text (lambda (op args) (ask session op args)) (the-selection session)))
  (if (hash? answer)
      (hash-ref answer 'text "")
      ""))

;; The command table, for every area above this one.
(provide commands
         session
         make-session
         session-file
         session-journal
         session-point
         session-selection
         session-layer
         the-point
         move-to
         the-selection
         select-from
         select-off
         selection-text
         the-layer
         set-layer!
         run-command
         command-names
         answer-line
         ask)
