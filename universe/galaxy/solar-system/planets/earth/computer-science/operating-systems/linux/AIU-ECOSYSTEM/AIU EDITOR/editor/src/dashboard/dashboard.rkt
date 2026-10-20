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
         "../routes/routes.rkt"
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
     (format "layer ~a  agent ~a ~a"
             (state-layer state)
             (hash-ref agent-status 'state)
             (hash-ref agent-status 'agent))]
    [("sidebar")
     (string-join
      (for/list ([route (in-list (route-commands))])
        (format "~a ~a -> ~a" (first route) (second route) (third route)))
      "\n")]
    [("status")
     (format "~a  ~a"
             (hash-ref agent-status 'state)
             (hash-ref agent-status 'on))]
    [else ""]))

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
;; counts, the pending edits and the layer the editor is in.
(define (session-state file journal)
  (define answer (ask-hot "open" (hasheq 'file file 'journal journal)))
  (define data (response-data answer))
  (hash 'file file
        'lines (hash-ref data 'lines "0")
        'bytes (hash-ref data 'bytes "0")
        'pending (hash-ref data 'pending "0")
        'layer "visual"))

;; The dashboard, for the entry above it.
(provide screen-width
         screen-height
         agent-status
         piece-content
         draw-dashboard
         session-state
         the-pieces
         pieces-of)
