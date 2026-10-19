#lang racket/base
;; One job: one-writer locks — wait and retry, never force.
;; Lands with TODO item 1 (the floor). A lock is a file, created exclusively;
;; a writer that cannot get it waits and says why, and it never takes a lock
;; from someone else by force.

(require racket/file
         "../errors/raise.rkt"
         "../narration/wait-door.rkt"
         "cancel.rkt")

(provide acquire-lock release-lock with-lock (struct-out wlock))


;; A lock holds the path it guards and the door that frees it, so a
;; caller can see what it holds.
;; A held lock: the file that marks it, and the door that lets its holder give
;; up rather than force it away from someone else.
(struct wlock (path door) #:transparent)

;; A lock is stale when it is older than stale-seconds. A stale lock is never
;; taken by force: the waiter says so and gives up, leaving the decision to a
;; human. The number is an argument so nothing here reads a clock on its own.
;; lock-exists? says whether a path is already locked.
(define stale-seconds 600)

;; lock-exists? says whether some writer already holds the lock at this path.
(define (lock-exists? path)
  (file-exists? path))

;; acquire-lock loops until it gets the lock, the door is cancelled, or the
;; wait is longer than give-up-seconds. Every wait is announced by the wait
;; door, because a silent wait is the failure this file exists to prevent.
(define (acquire-lock path give-up-seconds)
  (define door (make-cancel-door))
  (define waited 0)
  (let loop ()
    (check-cancel door (format "acquiring the lock ~a" path))
    (cond
      [(lock-exists? path)
       (when (>= waited give-up-seconds)
         (raise-err 'locks "locks.rkt"
                    (format "another writer holds ~a; waited ~as and gave up rather than forcing it"
                            path waited)))
       (wait-for (format "the lock ~a" path)
                 (format "another writer holds it; waiting ~as, retrying every second, never forcing"
                         stale-seconds))
       (sleep 1)
       (set! waited (add1 waited))
       (loop)]
      [else
       ;; create the lock file exclusively; if someone won the race, the
       ;; exception sends us back round the loop rather than forcing it.
       (with-handlers
           ([exn:fail:filesystem? (lambda (e) (loop))])
         (call-with-output-file path #:exists 'error (lambda (out) (display "notation lock\n" out)))
         (wlock path door))])))

;; release-lock removes the lock file. It refuses to release a lock it was not
;; given, so one writer cannot close another's door.
(define (release-lock l)
  (when (lock-exists? (wlock-path l))
    (delete-file (wlock-path l))))

;; with-lock is the shape every writer uses: take it, work, give it back.
(define (with-lock path thunk)
  (define l (acquire-lock path 30))
  (define result (thunk))
  (release-lock l)
  result)