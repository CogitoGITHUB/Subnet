#lang racket/base
;; One job: the dashboard — the meaning: what each piece shows, and the
;; call that draws it. The placement is the piece list (pieces.rkt) and
;; the drawing is Rust, in this same area (rule 09); this file says what
;; the pieces say and asks for the drawing.
;;
;; Every piece can show the agent status: idle, working, waiting for my
;; accept, which agent, on what (rule 10). The status is one thing here
;; and every piece that shows it says the same thing, so the screen
;; never disagrees with itself.
;;
;; Registered in plan/package-tree.org; lands with TODO item 7.

(require racket/list
         racket/string
         "../join/hot-path.rkt"
         "../join/protocol.rkt"
         "explorer.rkt"
         "pieces.rkt")

;; state-file answers the file of a state.
(define (state-file state) (hash-ref state 'file))

;; state-lines answers the number of lines of a state.
(define (state-lines state) (hash-ref state 'lines))

;; state-bytes answers the number of bytes of a state.
(define (state-bytes state) (hash-ref state 'bytes))

;; state-pending answers the number of unsaved edits of a state.
(define (state-pending state) (hash-ref state 'pending))

;; state-layer answers the layer the editor is in.
(define (state-layer state) (hash-ref state 'layer))

;; screen-width is the width of the screen the dashboard is drawn on.
(define screen-width 80)

;; screen-height is the height of the screen the dashboard is drawn on.
(define screen-height 24)

;; agent-status is the state of the agent the editor talks to: what it is
;; doing, which agent it is, and on what. There is no agent yet, so the
;; status is idle and names nothing.
(define agent-status
  (hash 'state "idle" 'agent "-" 'on "-"))

;; piece-content answers the text one piece shows, given the state of the
;; session: the file being edited, the counts, the pending edits and the
;; layer the editor is in. A piece with no text of its own shows nothing.
(define (piece-content name state)
  (case name
    [("modeline")
     (format "~a  ~a lines  ~a bytes  ~a pending"
             (state-file state)
             (state-lines state)
             (state-bytes state)
             (state-pending state))]
    [("buffer-bar")
     (format "layer ~a  agent ~a ~a  |  ~a"
             (state-layer state)
             (hash-ref agent-status 'state)
             (hash-ref agent-status 'agent)
             (git-line state))]
    [("sidebar")
     ;; The sidebar is the explorer: the keys of the editor's own tables
     ;; and what each one means, drawn from the tables themselves.
     (string-join (explorer-lines) "\n")]
    [("status")
     (format "~a  ~a"
             (hash-ref agent-status 'state)
             (hash-ref agent-status 'on))]
    [else ""]))

;; git-line answers the one line the editor shows about Git: the branch,
;; the state of the file in the working tree, and the counts of the
;; repository.
;;
;; The file's state in the index and in the working tree are two states,
;; and they are told apart when they differ: a file that is changed and
;; not staged says so. A file that is in no repository says that, and
;; never says the tree is clean.
(define (git-line state)
  (define branch (hash-ref state 'git-branch "-"))
  (define index (hash-ref state 'git-index "unknown"))
  (define working (hash-ref state 'git-state "unknown"))
  (if (string=? working "unknown")
      (format "~a  not in a repository" branch)
      (format "~a  ~a~a  ~a staged, ~a unstaged, ~a untracked"
              branch
              working
              (if (string=? index "unchanged") "" (format " (the index: ~a)" index))
              (hash-ref state 'git-staged "0")
              (hash-ref state 'git-unstaged "0")
              (hash-ref state 'git-untracked "0"))))

;; piece-fields answers one piece as the fields the drawing reads: the
;; name, the edge, the size, the order and the text, separated by tabs.
(define (piece-fields piece text)
  (string-join
   (list (piece-name piece)
         (piece-edge piece)
         (number->string (piece-size piece))
         (number->string (piece-order piece))
         text)
   "\t"))

;; piece-args answers the arguments of the drawing call: the width, the
;; height, the number of pieces and the pieces themselves.
(define (piece-args pieces state)
  (let loop ([rest pieces] [index 0] [args (hash 'width (number->string screen-width)
                                                'height (number->string screen-height))])
    (if (null? rest)
        (hash-set args 'count (number->string index))
        (loop (cdr rest)
              (+ index 1)
              (hash-set args
                        (string->symbol (format "piece~a" index))
                        (piece-fields (car rest) (piece-content (piece-name (car rest)) state)))))))

;; draw-dashboard asks the hot path to draw the pieces and answers the
;; lines of the screen, top first. The screen comes back as one text
;; with the lines separated by newlines.
(define (draw-dashboard pieces state)
  (define answer
    (ask-hot "dashboard"
             (piece-args pieces state)))
  (if (response-ok answer)
      (string-split (hash-ref (response-data answer) 'screen "") "\n")
      (list (format "FAIL the dashboard could not be drawn: ~a"
                    (hash-ref (response-data answer) 'what "the hot path refused the request")))))

;; session-state answers the state of the editing session: the file, the
;; counts, the pending edits, the layer the editor is in, and what Git
;; says about the file.
;;
;; The Git facts come from the shared layer over the same seam: the
;; branch, the file's own state in the index and in the working tree,
;; which are two different states, and the counts of the repository. A
;; file that is in no repository says so, and never says the tree is
;; clean.
(define (session-state file journal)
  (define answer (ask-hot "open" (hasheq 'file file 'journal journal)))
  (define data (response-data answer))
  (hash 'file file
        'lines (hash-ref data 'lines "0")
        'bytes (hash-ref data 'bytes "0")
        'pending (hash-ref data 'pending "0")
        'layer "visual"
        'git-branch (hash-ref data 'git-branch "-")
        'git-state (hash-ref data 'git-state (hash-ref data 'git-file-working "unknown"))
        'git-index (hash-ref data 'git-file-index "unknown")
        'git-staged (hash-ref data 'git-staged "0")
        'git-unstaged (hash-ref data 'git-unstaged "0")
        'git-untracked (hash-ref data 'git-untracked "0")))

;; The dashboard, for the entry above it.
(provide screen-width
         screen-height
         agent-status
         piece-content
         draw-dashboard
         session-state
         the-pieces
         pieces-of)
