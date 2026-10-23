#lang racket/base
;; One job: wait-for / wait-done; why is never blank.
;; Registered in plan/package-tree.org. Every blocking call announces itself
;; here before it blocks and reports here after it returns
;; (agents/verbosity.md): a WAIT with no WAIT-DONE is the exact line that names
;; a hang, so no block may go around this door.
;;
;; A wait token remembers the run, the label and the reason, so wait-done
;; repeats the reason instead of inventing a second one.
(require "narration.rkt"
         "../errors/err.rkt"
         "../errors/raise.rkt")

;; provide is the door itself: wait-for, wait-done and the token between them.
(provide (struct-out wait-token)
         wait-for
         wait-done)

;; wait-token is what wait-for hands back: the run it belongs to, the label, the
;; reason, the clock reading wait-done measures from, and the WAIT event's id.
(struct wait-token (run label why started-ms id) #:transparent)

;; wait-for announces a block before it happens and answers the token that
;; closes it. A blank reason is refused: "waiting" is not a reason.
(define (wait-for r label #:why why #:how [how "a blocking call"])
  (unless (and (string? why) (not (blank-string? why)))
    (raise-error "a wait reason was blank"
                 "narration/wait-for"
                 label
                 "no reason was given; a wait without a reason is a wait nobody can read"
                 #:rule 'wait/why-mandatory))
  (define e (narrate r 'WAIT label #:why why #:how how))
  (wait-token r label why (mono-ms) (event-id e)))

;; wait-done reports that the block returned, in how long, with the reason the
;; wait gave, and names the WAIT event as its parent so the pair reads as one
;; block in the feed.
(define (wait-done token #:result [result #f])
  (narrate (wait-token-run token)
           'WAIT-DONE
           (wait-token-label token)
           #:why (wait-token-why token)
           #:how "the block returned"
           #:result result
           #:parent (wait-token-id token)
           #:duration-ms (- (mono-ms) (wait-token-started-ms token))))
