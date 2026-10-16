#lang racket/base
;; profile-holds.rkt -- holds: profile/holds.rktd pins (name slot)
;; pairs so updates leave pinned packages alone. An absent file reads
;; as none held; a torn read refuses with kind 'config rather than
;; guessing; writes are idempotent and never lose other pins.

(require racket/file
         racket/list
         racket/path
         "../errors/error-type.rkt")

(provide
 ;; the holds surface; contracts stay on the facade
 read-holds
 profile-hold
 profile-unhold
 profile-held?)

;; path-string -> path, the holds file (absent reads as none held)
(define (holds-file profile-root)
  (build-path profile-root "holds.rktd"))

;; string string -> void, pins name real non-empty identities
(define (check-hold-identity name slot)
  (when (or (string=? name "") (string=? slot ""))
    (raise-pm-error 'config 'profile-hold "bad hold identity"
                    #:fields `(("name" . ,name) ("slot" . ,slot)))))

;; path-string -> (listof list), (name slot) pairs; torn reads refuse
(define (read-holds profile-root)
  (define f (holds-file profile-root))
  (if (not (file-exists? f))
      '()
      (let ([datum (read-holds-file f)])
        (if (holds-datum? datum)
            datum
            (raise-holds-bad f)))))

;; path -> jsexpr, one file read; failures become kind 'config
(define (read-holds-file f)
  (with-handlers ([exn:fail? (lambda (e) (raise-holds-bad f))])
    (call-with-input-file f read)))

;; path -> never returns, kind 'config naming the file
(define (raise-holds-bad f)
  (raise-pm-error 'config 'profile-hold "bad holds file"
                  #:fields `(("file" . ,(path->string f)))))

;; any -> boolean, list of two-string lists
(define (holds-datum? datum)
  (and (list? datum)
       (andmap holds-pair? datum)))

;; any -> boolean, one two-string list
(define (holds-pair? h)
  (and (list? h)
       (= 2 (length h))
       (string? (first h))
       (string? (second h))))

;; path-string (listof list) -> void
(define (write-holds! profile-root holds)
  (make-directory* profile-root)
  (call-with-output-file (holds-file profile-root)
    (lambda (out) (write holds out))
    #:exists 'truncate/replace))

;; path-string string string -> void, pin a slot (idempotent)
(define (profile-hold profile-root name slot)
  (check-hold-identity name slot)
  (define holds (read-holds profile-root))
  (unless (member (list name slot) holds)
    (write-holds! profile-root (append holds (list (list name slot))))))

;; path-string string string -> void, release a pin (idempotent)
(define (profile-unhold profile-root name slot)
  (check-hold-identity name slot)
  (define holds (read-holds profile-root))
  (define kept (filter (lambda (h) (not (equal? h (list name slot))))
                       holds))
  (unless (= (length kept) (length holds))
    (write-holds! profile-root kept)))

;; path-string string string -> boolean, is the slot pinned
(define (profile-held? profile-root name slot)
  (if (member (list name slot) (read-holds profile-root)) #t #f))
