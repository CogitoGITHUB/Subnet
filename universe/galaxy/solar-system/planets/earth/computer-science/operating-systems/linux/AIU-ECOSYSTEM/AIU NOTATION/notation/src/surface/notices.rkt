#lang racket/base
;; One job: what the boundary sends unasked — a document parsed, a document
;; changed — and the errors that come with them.
;; Registered in plan/package-tree.org (surface/notices.rkt). Lands with TODO
;; item 8 (build step 7, the engine surface).
;;
;; An answer is asked for; a notice is not. The host is typing, the tree
;; changes, and the boundary says so on its own — there is no call to wait for
;; and no document anybody requested. One event is one notice document, and a
;; document holding two events would ask the reader to tell them apart by
;; counting, which this shape never does.
;;
;; The errors here are the same =stray-text= errors the =check= command prints,
;; each with its line number (plan/package-tree.org, surface/notices.rkt), and
;; they carry no address: a notice can arrive for a document whose tree was
;; never built, and an address exists only when a tree does. The line number is
;; the position a reader can act on, and it is what =check= has always given.
;;
;;   NOTATION-NOTICE 1
;;   file "<path>"
;;   notice <kind> "<what>" "<detail>"
;;   error <kind> <line> "<what>" "<whatToDo>"
;;   end
;;
;; The kind is one of the two words named below, and a third is refused rather
;; than carried: a host meeting a kind it does not know must hear that the
;; shapes differ instead of reading a line that means nothing. The header is a
;; version of its own, separate from the answer document's, because the two
;; shapes change for different reasons and a reader must be able to refuse one
;; without refusing the other.
;;
;; This file requires answers.rkt for the quoting rule and nothing else — no
;; model, no meaning side. A host may read a notice with this file and the
;; contract alone, which is the same promise answers.rkt makes (rule 14).

(require racket/string
         "../errors/raise.rkt"
         "answers.rkt")

(provide notice-header
         notice-kinds
         notice-document
         read-notices
         (struct-out notice)
         (struct-out notice-error)
         (struct-out notices))


;; The version line of this shape, separate from the answer document's.
(define notice-header "NOTATION-NOTICE 1")

;; The two words an unasked event may be. A third is not added here without a
;; root decision: the vocabulary is the owner's, and this file only names the
;; two the boundary already speaks (contract/notation-engine-boundary.org,
;; "report the new parse and its errors").
(define notice-kinds '(parsed did-change))

;; One unasked event: what happened and the detail that makes it useful — for
;; =parsed=, the counts the editor shows; for =did-change=, the lines that
;; moved. detail is given every time, as "" when there is nothing more to say.
(struct notice (kind what detail) #:transparent)

;; One error that came with the event: the kind the =check= command prints,
;; the line it is on, what is wrong, and what the reader may do about it.
(struct notice-error (kind line what what-to-do) #:transparent)

;; A notice document that was read: the file it is about, the event, and every
;; error sent with it, in the order they were sent.
(struct notices (file event errors) #:transparent)


;; notice-document prints one event, with its errors, as the frozen text.
(define (notice-document n)
  (string-append
   (string-append notice-header "\n")
   (format "file ~a\n" (quoted-field (or (notices-file n) "")))
   (format "notice ~a ~a ~a~%"
          (notice-kind (notices-event n))
          (quoted-field (notice-what (notices-event n)))
          (quoted-field (notice-detail (notices-event n))))
   (apply string-append (map notice-error-text (notices-errors n)))
   (string-append "end\n")))

;; notice-error-text prints one error line: the same things =check= prints, and
;; nothing more. It is not the accessor notice-error-line that (struct-out
;; notice-error) already brings in: that one answers the line number, and a
;; reader must never have to ask which of the two a line of this file means.
(define (notice-error-text e)
  (format "error ~a ~a ~a ~a~%"
          (notice-error-kind e)
          (notice-error-line e)
          (quoted-field (notice-error-what e))
          (quoted-field (notice-error-what-to-do e))))


;; read-notices reads a notice document back. It refuses a version it does not
;; know, a kind it does not speak, an error with nothing to do about it, a
;; document with no event and a document with no =end= line — the same doors
;; answers.rkt opens, and for the same reasons: a reader must never skip a
;; line it does not understand.
(define (read-notices text)
  (define lines (string-split text "\n" #:trim? #f))
  (when (or (null? lines) (not (string=? (car lines) notice-header)))
    (raise-err 'notices "notices.rkt"
               (format "the notice does not start with ~a, so this reader does not know its shape; ask the host for a notice of the shape ~a names, and compare the version lines first" notice-header)))
  (define file-path #f)
  (define event #f)
  (define errors '())
  (define ended? #f)
  (let loop ([rest (cdr lines)])
    (cond
      [(null? rest) 'done]
      [ended? 'done]
      [else
       (define line (string-trim (car rest)))
       (cond
         [(string=? line "")
          (loop (cdr rest))]
         [(string=? line "end")
          (set! ended? #t)
          (loop (cdr rest))]
         [(string-prefix? line "file ")
          (set! file-path (unquoted-field (string-trim (substring line 5))))
          (loop (cdr rest))]
         [(string-prefix? line "notice ")
          (set! event (read-notice-line line))
          (loop (cdr rest))]
         [(string-prefix? line "error ")
          (set! errors (cons (read-notice-error-line line) errors))
          (loop (cdr rest))]
         [else
          (raise-err 'notices "notices.rkt"
                     (format "the notice holds a line this shape does not define (~a); a reader must not skip a line it does not know — ask the host for a notice of the shape ~a names" line notice-header))])]))
  (when (not ended?)
    (raise-err 'notices "notices.rkt"
               "the notice has no end line, so it is truncated and half an event would be read; read the whole line the host wrote, and ask again if it stops"))
  (when (not event)
    (raise-err 'notices "notices.rkt"
               (format "the notice carries no notice line, so nothing was announced; ask the host to send a notice of one of the kinds ~a, or to send nothing at all" notice-kinds)))
  (notices (or file-path "") event (reverse errors)))

;; read-notice-line reads =notice <kind> "<what>" "<detail>"= and refuses a
;; kind this boundary does not speak.
(define (read-notice-line line)
  (define parts (split-fields line))
  (unless (= (length parts) 4)
    (refuse-fields line parts '(kind what detail)))
  (define kind (list-ref parts 1))
  (unless (memq (string->symbol kind) notice-kinds)
    (raise-err 'notices "notices.rkt"
               (format "~a is not a kind this boundary announces (~a); the shapes differ — ask the host which kinds it speaks, and send one of ~a"
                       kind notice-kinds notice-kinds)))
  (notice kind
          (unquoted-field (list-ref parts 2))
          (unquoted-field (list-ref parts 3))))

;; read-notice-error-line reads =error <kind> <line> "<what>" "<whatToDo>"= and
;; refuses an error that arrives with nothing to do about.
(define (read-notice-error-line line)
  (define parts (split-fields line))
  (unless (= (length parts) 5)
    (refuse-fields line parts '(kind line what what-to-do)))
  (define what (unquoted-field (list-ref parts 3)))
  (define what-to-do (unquoted-field (list-ref parts 4)))
  (when (or (string=? what "") (string=? what-to-do ""))
    (raise-err 'notices "notices.rkt"
               (format "the ~a error on line ~a arrives with what ~a and what to do ~a; an error that cannot say what to do is not an error yet — send both, or leave the line out"
                       (list-ref parts 1) (list-ref parts 2) what what-to-do)))
  (notice-error (list-ref parts 1)
                (field-number line (list-ref parts 2) "line")
                what
                what-to-do))

;; refuse-fields says a line does not hold the fields the shape freezes, and
;; what to do about it.
(define (refuse-fields line parts fields)
  (raise-err 'notices "notices.rkt"
             (format "~a holds ~a fields where the shape names ~a; a field is missing or an extra one arrived — send a notice of the shape ~a names"
                     line (length parts) fields notice-header)))

;; field-number reads a field that must hold a whole number. A field that is
;; not a number is a broken shape, not a zero: 0 means "not known" and is only
;; ever written on purpose.
(define (field-number line field what)
  (define n (string->number field))
  (unless (and n (exact-integer? n))
    (raise-err 'notices "notices.rkt"
               (format "~a is ~a in ~a where the shape says a whole number — write the field as a number, and send a notice of the shape ~a names"
                       what field line notice-header)))
  n)
