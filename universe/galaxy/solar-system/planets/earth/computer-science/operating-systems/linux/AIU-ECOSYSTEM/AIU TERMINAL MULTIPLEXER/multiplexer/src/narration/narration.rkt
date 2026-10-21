#lang racket/base
;; One job: a run's voice — open, step, note, warn, skip, decide.
;; Registered in plan/package-tree.org. The voice stamps and numbers every event
;; here, because the schema (events.rkt) decides nothing and the printer
;; (print-console.rkt) only prints: one run, one counter, one clock.
;;
;; why is mandatory on step, decide, skip, fail and wait; a blank reason raises
;; an mp-error instead of inventing a default (agents/narration.md, rule 1).
(require "events.rkt"
         "print-console.rkt"
         "../errors/err.rkt"
         "../errors/raise.rkt")

;; provide is a run's voice and the two readings a wait door needs from it: the
;; monotonic clock and an event's id.
(provide (struct-out run)
         open-run
         narrate
         narrate-step
         narrate-note
         narrate-warn
         narrate-skip
         narrate-decide
         narrate-end
         mono-ms
         event-id)

;; run is one run's voice: its name, the id that completes its event names, its
;; one sequence counter, and the monotonic reading its durations come from.
(struct run (name id seq started-ms) #:mutable)

;; two-digit answers an hour, minute or second as two characters, so every stamp
;; is the same width and lines line up down the screen.
(define (two-digit n)
  (if (< n 10) (format "0~a" n) (format "~a" n)))

;; utc-stamp answers the wall-clock stamp "HH:MM:SSZ": for humans only, never
;; for a duration.
(define (utc-stamp)
  (define d (seconds->date (current-seconds)))
  (format "~a:~a:~aZ"
          (two-digit (date-hour d))
          (two-digit (date-minute d))
          (two-digit (date-second d))))

;; mono-ms answers the monotonic clock in milliseconds: durations come from
;; here, so a clock change cannot skew them.
(define (mono-ms)
  (current-inexact-monotonic-milliseconds))

;; next-seq answers the run's next sequence number and moves the counter on.
;; One counter per run, shared by nested work, so ordering survives nesting.
(define (next-seq r)
  (define n (add1 (run-seq r)))
  (set-run-seq! r n)
  n)

;; why-required? answers whether a kind may not be narrated without a reason:
;; the four kinds the schema demands, plus the wait door's two.
(define (why-required? kind)
  (if (memq kind '(STEP DECIDE SKIP FAIL WAIT WAIT-DONE)) #t #f))

;; require-why refuses a blank reason for a kind that needs one, before the
;; event is made, so there are no silent steps and no silent skips.
(define (require-why kind why where)
  (when (why-required? kind)
    (unless (and (string? why) (not (blank-string? why)))
      (raise-error "a narration reason was blank"
                   "narration/narrate"
                   where
                   "no reason was given; why is mandatory on step, decide, skip, fail and wait"
                   #:rule 'narration/why-mandatory))))

;; event-id answers the name of one event, "run#seq", which is what a nested
;; event names as its parent.
(define (event-id e)
  (format "~a#~a" (event-run-id e) (event-seq e)))

;; narrate makes one event, stamped and numbered here, hands it to the one
;; printer, and answers it so a caller can name it as a parent.
(define (narrate r kind what
                 #:who [who (run-name r)]
                 #:why [why #f]
                 #:how [how #f]
                 #:result [result #f]
                 #:depth [depth 0]
                 #:parent [parent #f]
                 #:duration-ms [duration-ms 0])
  (require-why kind why what)
  (define e (event (format "~a#~a" (run-name r) (run-id r))
                   (next-seq r)
                   parent
                   kind
                   depth
                   who
                   what
                   why
                   how
                   #f
                   #f
                   result
                   (utc-stamp)
                   (- (mono-ms) (run-started-ms r))
                   duration-ms))
  (print-event e)
  e)

;; open-run starts the voice of one run: a name, a number, a fresh counter and
;; the opening stamp. It emits START, so every run opens with a line.
(define (open-run name)
  (define r (run name (random 1000000) 0 (mono-ms)))
  (narrate r 'START name #:why "the run was asked to start" #:how "open-run")
  r)

;; narrate-step records one finished step; why is required.
(define (narrate-step r what #:why why #:how [how #f] #:depth [depth 0])
  (narrate r 'STEP what #:why why #:how how #:depth depth))

;; narrate-note records information that decided nothing; why is optional.
(define (narrate-note r what #:why [why #f])
  (narrate r 'INFO what #:why why))

;; narrate-warn records something a reader should see but that stopped nothing.
(define (narrate-warn r what #:why [why #f])
  (narrate r 'WARN what #:why why))

;; narrate-skip records work not done; why is required, so no skip is silent.
(define (narrate-skip r what #:why why)
  (narrate r 'SKIP what #:why why))

;; narrate-decide records a choice and what it chose; why is required, because
;; a decision without a reason cannot be reviewed.
(define (narrate-decide r what #:why why #:result [result #f])
  (narrate r 'DECIDE what #:why why #:result result))

;; narrate-end closes the run's voice with what it produced.
(define (narrate-end r #:result [result #f])
  (narrate r 'END "the run ends" #:why "the work finished" #:result result))
