#lang racket/base
;; One job: the boundary — the calls every adapter implements, over one
;; agent's own client. The names are the contract's
;; (../contract/ai-link-boundary.org): open or attach a session; send a
;; bundle; subscribe to the session's events; answer a permission ask;
;; cancel; end. Nothing agent-specific crosses this file: the program
;; above it names the agent, and the client below it does the talking.
;;
;; The adapter is the boundary ONE WAY. What the agent cannot do today
;; is refused BY NAME — there is no silent downgrade (rule 08).
;;
;; The stop switch is asked on every call: while it is thrown, no
;; bundle goes to any agent session for this project (D-010).
;;
;; Registered in plan/package-tree.org; lands with TODO item 9.

(require racket/file
         racket/list
         racket/port
         racket/string
         "../machine/directories.rkt"
         "../machine/stop-switch.rkt"
         "bundle.rkt"
         "opencode-adapter.rkt")

;; session-file is where the handle of the session lives: the handle
;; outlives the caller's screen, like the holder's shells do. The file
;; is written when a session is opened and read when one is needed.
(define session-file
  (build-path (state-dir) "agent-session"))

;; attach opens a session with the agent, or attaches to the one that is
;; already open, and answers the handle. The handle is written to the
;; state directory, so the next call finds the same session.
(define (attach client)
  (define existing (read-handle))
  (if existing
      (values existing #f)
      (let-values ([(handle refusal) (client-open client)])
        (if handle
            (begin (write-handle handle) (values handle #f))
            (values #f refusal)))))

;; read-handle answers the handle of the session that is open, or
;; nothing when no session is open.
(define (read-handle)
  (if (file-exists? session-file)
      (let ([text (call-with-input-file session-file
                                       (lambda (port) (read-line port)))] )
        (if (string=? (string-trim text) "") #f (string-trim text)))
      #f))

;; write-handle writes the handle of the session that is open.
(define (write-handle handle)
  (ensure-dir (state-dir))
  (call-with-output-file session-file
    (lambda (port) (display handle port))
    #:exists 'truncate)
  handle)

;; forget-handle forgets the handle: the session is not open any more.
(define (forget-handle)
  (when (file-exists? session-file)
    (delete-file session-file))
  #f)

;; deliver sends a bundle to the agent and answers what came back.
;;
;; The stop switch is asked FIRST: while it is thrown, no bundle goes to
;; any agent session for this project (D-010).
(define (deliver client handle bundle)
  (cond
    [(stopped?)
     (values #f (refusal "the stop switch is thrown: every agent session for this project stops"))]
    [(not (bundle? bundle))
     (values #f (refusal "there is no bundle to send"))]
    [(not handle)
     (values #f (refusal "no session is open: attach an agent first"))]
    [else
     (define-values (message refusal) (client-deliver client handle (bundle-text bundle)))
     (if message (values message #f) (values #f refusal))]))

;; subscribe opens the agent's event feed and answers the stream, or
;; nothing when the feed cannot be opened. The feed is opened BEFORE the
;; bundle goes out: an event that came before the feed was open is an
;; event nobody saw.
(define (subscribe client)
  (client-open-feed client))

;; events reads the agent's events until the turn ends or the agent asks
;; for a permission, and answers the events and the text the agent said.
(define (events client handle feed)
  (if (not handle)
      (values '() "" (refusal "no session is open: attach an agent first"))
      (client-turn feed handle)))

;; answer-permission answers one permission ask the way the human said:
;; once, always or reject. The approval is never inferred (rule 07).
(define (answer-permission client handle request-id decision)
  (cond
    [(stopped?)
     (values #f (refusal "the stop switch is thrown: every agent session for this project stops"))]
    [(not handle)
     (values #f (refusal "no session is open: attach an agent first"))]
    [else (client-reply client handle request-id decision)]))

;; cancel cancels the turn the agent is in.
(define (cancel client handle)
  (if (not handle)
      (values #f (refusal "no session is open: attach an agent first"))
      (client-cancel client handle)))

;; end-session ends the session and forgets the handle.
(define (end-session client handle)
  (if (not handle)
      (values #f (refusal "no session is open: attach an agent first"))
      (let-values ([(ok refusal) (client-end client handle)])
        (forget-handle)
        (if ok (values #t #f) (values #f refusal)))))

;; pins answers the two pins: the boundary version the adapter
;; implements and the agent version it was verified against.
(define (pins client)
  (hash 'boundary boundary-version
        'agent (client-version client)))

;; refusal answers the refusal of the boundary: what it cannot do, and
;; what to do about it. A refusal names the agent and the reason.
(define (refusal what)
  (hash 'kind "err-no-agent"
        'who "opencode"
        'what what
        'what_to_do "attach an agent first: the agent boundary is the one way to reach one"))

;; The boundary, for the send area and the entry above it.
(provide attach
         read-handle
         write-handle
         forget-handle
         deliver
         subscribe
         events
         answer-permission
         cancel
         end-session
         pins
         refusal)
