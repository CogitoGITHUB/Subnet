#lang racket/base
;; One job: one-writer locks — wait and retry, never force.
;; Registered in plan/package-tree.org. A lock is a directory, because creating
;; a directory is atomic here and needs no package. A second writer waits, says
;; so through the wait door, and retries; it never removes a lock it did not
;; create, and it gives up with an error naming who holds it. Nothing forces.
(require "../errors/err.rkt"
         "../errors/raise.rkt"
         "../narration/wait-door.rkt"
         "directories.rkt")

;; provide is the lock itself and its two acts: acquire, release.
(provide (struct-out lock)
         acquire-lock!
         release-lock!
         lock-root)

;; lock is one held lock: where it is, who holds it and why they do.
(struct lock (path who why) #:transparent)

;; lock-root answers the directory holding every lock: state, not config,
;; because a lock is a fact about running work.
(define (lock-root)
  (build-path (xdg-state-home) "multiplexer" "locks"))

;; lock-slot answers the directory one lock name uses.
(define (lock-slot name)
  (build-path (lock-root) name))

;; owner-path answers the file inside a lock that names its holder.
(define (owner-path path)
  (build-path path "owner"))

;; write-text writes a string to a file, replacing what was there; a lock's
;; owner record is written in one call, with nothing else left open.
(define (write-text path text)
  (define out (open-output-file path #:exists 'replace))
  (write-string text out)
  (close-output-port out))

;; read-text answers a whole file as one string, or #f when it cannot be read.
;; The owner record is small, and this keeps the package on racket/base alone.
(define (read-text path)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define in (open-input-file path))
    (define text
      (let loop ([chars '()])
        (define c (read-char in))
        (if (eof-object? c)
            (list->string (reverse chars))
            (loop (cons c chars)))))
    (close-input-port in)
    text))

;; parent-dir answers the directory that holds one path, by cutting at the last
;; separator. It never asks the filesystem, so the parent of a path that does
;; not exist yet is still answered — which is what creating it needs.
(define (parent-dir path)
  (define s (if (path? path) (path->string path) path))
  (define cut
    (let loop ([i (sub1 (string-length s))])
      (cond
        [(< i 0) 0]
        [(char=? (string-ref s i) #\/) i]
        [else (loop (sub1 i))])))
  (if (zero? cut) "/" (substring s 0 cut)))

;; ensure-dir creates a directory and every parent it needs, one level at a
;; time, because this phone's racket/base has no make-directory*.
(define (ensure-dir path)
  (unless (directory-exists? path)
    (define s (if (path? path) (path->string path) path))
    (define parent (parent-dir s))
    (unless (equal? parent s)
      (ensure-dir parent))
    (with-handlers ([exn:fail:filesystem? (lambda (e) (void))])
      (make-directory path))))

;; take answers whether this process created the lock directory just now: the
;; one atomic act that decides a single writer.
(define (take path)
  (with-handlers ([exn:fail:filesystem? (lambda (e) #f)])
    (make-directory path)
    #t))

;; starts-with? answers whether a string begins with a prefix, using only
;; racket/base so the package needs no extra collection.
(define (starts-with? s prefix)
  (and (>= (string-length s) (string-length prefix))
       (string=? (substring s 0 (string-length prefix)) prefix)))

;; holder-note answers what the owner record says, for an error that must name
;; who holds the lock. A missing record is said to be missing.
(define (holder-note path)
  (define text (read-text (owner-path path)))
  (if (string? text) text "no owner record (a lock from a writer that has died)"))

;; retry tries the lock again, pausing between tries, and answers whether the
;; last try made the directory. left is the number of tries still allowed.
(define (retry path left pause-ms)
  (cond
    [(<= left 0) #f]
    [else
     (sleep (/ pause-ms 1000.0))
     (if (take path) #t (retry path (sub1 left) pause-ms))]))

;; acquire-lock! takes one writer's lock for one name, waiting and retrying
;; while another writer holds it, and answers the lock. It announces the wait
;; through the wait door and never removes a lock it did not create.
(define (acquire-lock! run name #:who who #:why why
                       #:tries [tries 50]
                       #:pause-ms [pause-ms 200])
  (when (blank-string? who)
    (raise-error "the lock holder was not named"
                 "machine/locks acquire-lock!"
                 name
                 "a lock must say who holds it, so the next writer can ask"
                 #:rule 'locks/who-required))
  (when (blank-string? why)
    (raise-error "the lock reason was blank"
                 "machine/locks acquire-lock!"
                 name
                 "a lock must say why it is held, so waiting is readable"
                 #:rule 'locks/why-required))
  (define path (lock-slot name))
  (ensure-dir (lock-root))
  (define got-now (take path))
  (define token
    (if got-now
        #f
        (wait-for run name
                  #:why (format "~a is held by another writer; ~a; waiting and retrying"
                                name why)
                  #:how "the one-writer lock directory")))
  (define got (if got-now #t (retry path tries pause-ms)))
  (when token
    (wait-done token #:result (if got "the lock was released to me" "no lock after the last try")))
  (if got
      (begin
        (write-text (owner-path path) (format "~a\n~a\n~a\n" who why (current-seconds)))
        (lock path who why))
      (raise-error "the lock stayed held by another writer"
                   "machine/locks acquire-lock!"
                   (path->string path)
                   (format "~a; waited ~a tries and forced nothing" why tries)
                   #:rule 'locks/never-force
                   #:detail (holder-note path))))

;; release-lock! removes the lock this process holds: the owner record first,
;; then the directory. A lock whose owner record names someone else is refused,
;; so a lock is never taken from another writer.
(define (release-lock! l)
  (define path (lock-path l))
  (cond
    [(not (directory-exists? path)) (void)]
    [else
     (define note (read-text (owner-path path)))
     (define mine (and (string? note)
                       (starts-with? note (format "~a\n" (lock-who l)))))
     (unless mine
       (raise-error "the lock is not mine to release"
                    "machine/locks release-lock!"
                    (path->string path)
                    "the owner record names another writer, or is missing; removing it breaks one"
                    #:rule 'locks/never-force))
     (when (file-exists? (owner-path path))
       (delete-file (owner-path path)))
     (delete-directory path)]))
