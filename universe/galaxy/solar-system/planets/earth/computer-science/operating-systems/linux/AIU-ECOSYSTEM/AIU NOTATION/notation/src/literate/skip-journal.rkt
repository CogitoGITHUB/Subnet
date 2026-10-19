#lang racket/base
;; One job: a changed chunk rebuilds, an unchanged one SKIPs naming the hash.
;; Registered in plan/package-tree.org (literate/skip-journal.rkt). Lands with
;; TODO item 6 (build step 5, literate code).
;;
;; The store is content-addressed: every entry is a file whose NAME is the hash
;; of what was sent, and whose two lines are the target it went to and the hash
;; of the bytes that were written there. Nothing in it is a timestamp — no
;; clock is read anywhere in this package — and nothing in it decides anything;
;; it only answers two questions: was this exact content already written to
;; this exact target, and is this file one of ours to replace?
;;
;; So the skip test is three steps and all three must hold:
;;   1. an entry exists for this chunk hash and this target,
;;   2. the target file is still there,
;;   3. the target file now hashes to the hash stored beside it.
;; If any one fails the chunk is sent again. The disk is what a reader gets, so
;; a file somebody changed by hand outranks anything the store remembers; a
;; store that could say "unchanged" about a file that no longer is would be a
;; lie told to the reader.
;;
;; The sentence a skip speaks is written here and nowhere else, and this file
;; speaks it: a caller receives a decision and never writes the skip line
;; itself. What it says is in the reason of the decision, which is the same
;; sentence the event carries:
;;
;;   skip: chunk build → plan/FILE-INVENTORY.org — unchanged; the same content
;;   hash 5f2c1e0a9d8b7c6e5f4a3b2c1d0e9f8a is already written there, so nothing
;;   was sent
;;
;; Every read and every write here goes through the wait door, because both
;; touch a disk that may be slow, full or gone; a run that hangs on a disk
;; without saying so is the failure this package exists to prevent.

(require openssl/md5
         racket/file
         racket/path
         racket/port
         racket/string
         "../errors/raise.rkt"
         "../machine/directories.rkt"
         "../narration/narration.rkt"
         "../narration/wait-door.rkt")

(provide content-hash text-hash hash-together store-path decide-skip record-send
         forget-sent store-owns-target? decision-sends?
         (struct-out skip-decision))


;; What a run decided about one chunk and one target: send it, or leave it
;; alone. hash is the content hash the decision was made on, so a caller may
;; show it without asking for it again, and reason is the sentence a reader
;; gets — the same words the event carries, never a second wording.
(struct skip-decision (outcome hash reason) #:transparent)

;; The outcomes: 'skip, and the three ways of writing. 'first is content the
;; store has never seen, 'again is content whose target has gone, 'stale is
;; content whose target no longer holds what was written. Which of the three it
;; was is in the reason, because "sent for the first time" and "sent again"
;; are different things to a reader watching a run.
(define write-outcomes '(first again stale))

;; decision-sends? answers whether a decision means the chunk is written. The
;; three write outcomes are named in one place and matched in one place, so a
;; caller never spells one out and never has to read the reasons to know.
(define (decision-sends? d)
  (and (memq (skip-decision-outcome d) write-outcomes) #t))

;; An md5 digest is 32 lowercase hex characters, and that is what makes an
;; entry name recognizable rather than arbitrary.
(define hash-length 32)

;; The gap between the parts of a hash. A NUL cannot appear in a line of a
;; page, so two different lists of parts can never join into one string.
(define part-gap (string (integer->char 0)))


;; content-hash is the one digest in the package: it reads a port and answers
;; the hash of every byte in it as lowercase hex. It streams, so hashing a
;; large generated file costs no more memory than hashing a small one.
;;
;; md5 is chosen for change detection and for nothing else. It is here because
;; the crate has no dependencies and this build's Racket ships openssl/md5;
;; it is not a security digest and no decision in this package rests on it
;; being one. Swapping it later changes every hash in the store once, which is
;; why the length is a named value and not a number written twice.
(define (content-hash in)
  (md5 in))

;; text-hash is content-hash for text this package already holds.
(define (text-hash text)
  (content-hash (open-input-string text)))

;; hash-together is the hash of several things taken at once. A chunk is not
;; only its source: what it depends on and where it goes are part of what it
;; is, so all of them go into one name and two chunks can never share one.
(define (hash-together parts)
  (text-hash (string-join parts part-gap)))

;; hash-shaped? says a string is a hash this file wrote, and not something a
;; disk returned that has been edited by hand.
(define (hash-shaped? s)
  (and (string? s)
       (= (string-length s) hash-length)
       (andmap (lambda (c) (or (char<=? #\0 c #\9) (char<=? #\a c #\f)))
               (string->list s))))


;; store-path is where the entries for one document live: a directory of its
;; own under the run's state directory, named by the hash of the document's
;; path. Two documents never share a store, and a document that was renamed
;; starts a fresh one instead of answering for a file that is no longer there.
;; The state directory is the one place HOME is read
;; (machine/directories.rkt), so no file here reads an environment name.
(define (store-path document-path)
  (build-path (notation-state-dir) "generations" (text-hash document-path)))

;; entry-path is the entry for one content hash at one target. The target is
;; part of the entry's name because sending the same source to two files is two
;; different acts, and one of them being written must not skip the other.
(define (entry-path store target-path hash)
  (build-path store (hash-together (list target-path hash))))


;; decide-skip answers what to do with one chunk at one target, and says the
;; skip out loud when the answer is a skip. Every reason it gives is a
;; sentence a reader may act on, and no path through this file is silent.
(define (decide-skip store chunk-name target-path hash)
  (define entry (entry-path store target-path hash))
  (cond
    [(not (file-exists? entry))
     (skip-decision 'first hash
                    "the store has never seen this content, so the chunk is sent")]
    [else
     (define written (stored-target-hash entry))
     (cond
       [(not written)
        (skip-decision 'stale hash
                       "the store's entry for this hash cannot be read, so the chunk is sent again rather than trusted")]
       [(not (file-exists? target-path))
        (skip-decision 'again hash
                       "the store knows this hash but the target is gone, so the chunk is sent again")]
       [else
        (define now (target-file-hash target-path))
        (cond
          [(not now)
           (skip-decision 'stale hash
                          "the target could not be read back, so the chunk is sent again")]
          [(equal? now written)
           ;; The item's own done-when, and the only place it is written: the
           ;; chunk is unchanged, the hash that matched is named, and the run
           ;; says it did not send the chunk.
           (define reason
             (format "unchanged; the same content hash ~a is already written there, so nothing was sent"
                     hash))
           (say-skip (format "chunk ~a → ~a" chunk-name target-path) reason)
           (skip-decision 'skip hash reason)]
          [else
           (say-warn (format "the store entry for the chunk ~a" chunk-name)
                     (format "the store says hash ~a went to ~a, but that file now hashes to ~a; sent again, because the disk is what a reader gets"
                             hash target-path now))
           (skip-decision 'stale hash
                          "the file on disk no longer matches what the store recorded, so the chunk is sent again")])])]))


;; stored-target-hash answers the hash of the bytes that were written, or #f
;; when the entry says nothing a run could trust. It is the second line of an
;; entry; the first line is the target it was written to.
(define (stored-target-hash entry)
  (with-handlers ([exn:fail:filesystem? (lambda (e) (say-entry-unreadable entry) #f)])
    (define lines (entry-lines entry))
    (define text (if (null? (cdr lines)) "" (string-trim (cadr lines))))
    (cond
      [(hash-shaped? text) text]
      [else (say-entry-unreadable entry) #f])))

;; entry-target answers the path an entry was written for, or #f when the entry
;; cannot be read. A path holds spaces but never a newline, so the first line
;; of an entry is the whole path and needs no quoting.
(define (entry-target entry)
  (with-handlers ([exn:fail:filesystem? (lambda (e) #f)])
    (define lines (entry-lines entry))
    (if (null? lines) #f (car lines))))

(define (entry-lines entry)
  (string-split (file->string entry #:mode 'binary) "\n" #:trim? #f #:repeat? #f))

(define (say-entry-unreadable entry)
  (say-warn (format "the store entry ~a" (file-name-from-path entry))
            "it does not hold a hash this file wrote; the chunk is sent again rather than trusted"))

;; store-owns-target? answers whether this document's store holds anything sent
;; to a path. It is the answer generation/write.rkt stands on: a file no run
;; of this document wrote is not ours to replace. Reading the store is a block
;; on a disk, so the wait door says why before and after.
(define (store-owns-target? store target-path)
  (with-wait (format "reading the store at ~a" store)
             (format "to learn whether this document already sent ~a there; a file no run sent is never replaced" target-path)
    (for/or ([h (sent-hashes store)])
      (equal? target-path (entry-target (build-path store h))))))

;; target-file-hash hashes the file that is on disk now, or #f when it cannot
;; be read. Reading a file is a block on a disk that may be slow or gone, so
;; the wait door says why before and after.
(define (target-file-hash path)
  (with-handlers ([exn:fail:filesystem? (lambda (e) #f)])
    (with-wait (format "reading ~a" path)
               "to compare it with the hash stored beside it; a file that cannot be read is sent again, never trusted"
      (call-with-input-file path content-hash))))


;; record-send writes the entry that stands for what was just written: this
;; content hash now means this target, and these are the bytes it was written
;; as. The entry is two lines — the target on the first, the hash it was
;; written as on the second — because the writer has to be able to ask whether
;; a file is its own, and an entry that could not answer that would be a store
;; that remembers hashes and nothing about where they went.
;;
;; It is called after the file is in place and never before, so the store never
;; claims something the disk does not have.
(define (record-send store target-path hash written-text)
  (with-wait "recording what was sent"
             "so that a later run which finds the same content again may skip it instead of writing it again"
    (ensure-dir store)
    (call-with-output-file (entry-path store target-path hash)
                           #:exists 'truncate
                           (lambda (out)
                             (display target-path out)
                             (display "\n" out)
                             (display (text-hash written-text) out)))))

;; sent-hashes lists the hashes the store holds, by name, because the name is
;; the hash. A store that does not exist yet holds nothing.
(define (sent-hashes store)
  (if (directory-exists? store)
      (map (lambda (p) (file-name-from-path p)) (directory-list store))
      '()))

;; forget-sent removes the entries no chunk needs any more. An entry holds one
;; hash and one path, so removing one costs nothing that cannot be made again
;; and the next run simply writes it again. It is still said out loud, because
;; a run that removes files must not do it quietly.
(define (forget-sent store keep)
  (define gone (filter (lambda (h) (not (member h keep))) (sent-hashes store)))
  (cond
    [(null? gone) '()]
    [else
     (with-wait (format "forgetting ~a store entry(ies)" (length gone))
                "an entry holds one hash and one path; removing one loses nothing that cannot be made again"
       (for-each (lambda (h) (delete-file (build-path store h))) gone))
     (say-note "the generation store"
               (format "~a entry(ies) no chunk needs any more were removed; each held one hash, so nothing was lost"
                       (length gone)))
     gone]))
