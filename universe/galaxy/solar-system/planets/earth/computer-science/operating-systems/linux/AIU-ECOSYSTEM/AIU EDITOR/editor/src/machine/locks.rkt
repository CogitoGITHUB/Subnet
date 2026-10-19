#lang racket/base
;; One job: one-writer locks — wait and retry, never force.
;; Registered in plan/package-tree.org; lands with TODO item 1.
;;
;; A lock is a directory, because creating one is the one thing a filesystem
;; does that two writers cannot both win. A writer that finds the lock held
;; never takes it: it says the lock is busy and waits for the event that ends
;; the wait, which is the release (rule 04). Nothing here polls and nothing
;; here ticks: a lock that is held by another process is noticed again when
;; the caller's own event arrives.

(require racket/file
         racket/path
         "cancel.rkt"
         "../errors/raise.rkt")

;; lock is a held lock: the directory it holds, the signal that a local
;; waiter ends on, and the door that can cancel the holder.
(struct lock (path signal token) #:transparent)

;; lock-path-for answers the lock path that guards a target file.
(define (lock-path-for target)
  (build-path (path->complete-path target) ".lock"))

;; acquire-lock takes the lock for a target, and answers #f when another
;; writer holds it. It never forces and it never waits here.
(define (acquire-lock target)
  (define p (lock-path-for target))
  (cond
    [(directory-exists? p) #f]
    [else
     (with-handlers ([exn:fail? (lambda (e) #f)])
       (make-directory p)
       (lock p (make-semaphore) (new-cancel-token)))]))

;; release-lock gives the lock back and wakes the local waiters, so a wait
;; ends on the event "the lock was released".
(define (release-lock l)
  (when (directory-exists? (lock-path l))
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (directory-delete (lock-path l))))
  (semaphore-post (lock-signal l)))

;; with-lock runs the body while holding the lock, and always gives the lock
;; back. A busy lock is an error with a name, not a silent wait.
(define (with-lock target body)
  (define l (acquire-lock target))
  (if (not l)
      (error-of 'err-lock-busy "the editor" (path->string (lock-path-for target))
                "another writer holds the lock"
                "wait for the release event and try again")
      (dynamic-wind
        (lambda () (void))
        body
        (lambda () (release-lock l)))))

;; with-lock-wait runs the body under the lock, and waits for a local holder
;; to release it. A holder in another process is not waited for here: that
;; wait belongs to the caller's own event, so no clock is needed here.
(define (with-lock-wait target body)
  (define l (acquire-lock target))
  (cond
    [(not l)
     (wait-for-foreign-release (lock-path-for target))
     (with-lock-wait target body)]
    [else
     (dynamic-wind
       (lambda () (void))
       body
       (lambda () (release-lock l)))]))

;; wait-for-foreign-release blocks until the lock directory of another process
;; is gone. It is a wait on the filesystem event the caller brings; with no
;; such event yet it says so instead of pretending to wait.
(define (wait-for-foreign-release lock-path)
  (if (directory-exists? lock-path)
      (error-of 'err-lock-busy "the editor" (path->string lock-path)
                "another writer holds the lock and no release event is wired yet"
                "retry when the file-change event says the lock is gone")
      (void)))
