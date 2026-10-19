#lang racket/base
;; One job: the total predicates — the shapes a value may be refused for.
;; Lands with TODO item 1 (the tree lands).
;;
;; plan/package-tree.org registers one file for this area (security/security.rkt,
;; "the total predicates: output-safe?, state-changing?, refusals"). The area
;; keeps that name for the refusals (security.rkt) and puts the predicates here,
;; because one file has one job; widening the register is the owner's edit and
;; is not this directory's.
;;
;; Every predicate below is pure: it reads a value, answers a question about its
;; shape, and stops. No clock, no disk, no environment, and no raise — a refusal
;; is ../errors/raise.rkt's to make, never this file's.
;;
;; The four path questions are the ones literate/targets.rkt already asks in its
;; own door (writable-path) and generation/write.rkt asks once more for the
;; document itself. They are asked in one place so every door may ask them the
;; same way. Nothing outside this area imports them yet: targets.rkt keeps its
;; own refusals until that area is changed, which is the owner's call.

(require racket/path
         racket/string)

(provide output-safe? write-facing-predicates
         path-names-no-file? path-is-a-directory? path-climbs-out?
         path-is-absolute? target-names-the-document? place-not-writable?
         opaque-body-reached?)


;; The convention every predicate here follows: it answers whether the value is
;; refused, so #t refuses and #f lets the value through. output-safe? below is
;; the one exception and says so: it answers the writer's question, may this be
;; written, which is the opposite way round.

;; path-names-no-file? answers whether a path, trimmed, is empty: an into: value
;; that names nothing at all. A target must name one file, and this is the case
;; where it names none.
(define (path-names-no-file? path)
  (string=? (string-trim path) ""))

;; path-is-a-directory? answers whether a path ends in "/", which is how a
;; written target says "a directory". A target is one file and never a place.
(define (path-is-a-directory? path)
  (string-suffix? (string-trim path) "/"))

;; path-climbs-out? answers whether any segment of a path is "..", which is a
;; path leaving the one directory the document owns.
(define (path-climbs-out? path)
  (for/or ([seg (string-split (string-trim path) "/" #:trim? #f #:repeat? #f)])
    (string=? seg "..")))

;; path-is-absolute? answers whether a path names a place on the machine by its
;; own root, so a target reaches anywhere at all. A target is written beside the
;; document.
(define (path-is-absolute? path)
  (absolute-path? (string-trim path)))

;; output-safe? is the total predicate a writer asks before it writes: the path
;; names one file, it is relative, and it does not climb out. Two questions it
;; cannot answer are rules beside it and not this file's: whether the target is
;; the document itself, and whether an earlier run of this document sent it.
(define (output-safe? path)
  (and (not (path-names-no-file? path))
       (not (path-is-a-directory? path))
       (not (path-climbs-out? path))
       (not (path-is-absolute? path))))

;; target-names-the-document? answers whether a target and the document are one
;; file written two ways. It compares the two paths once simplified and asks no
;; device and no inode: the case that costs the source is a target naming the
;; document, and that is a question about spelling, not about the disk.
(define (target-names-the-document? target document-path)
  (equal? (simplify-path target) (simplify-path document-path)))

;; place-not-writable? answers whether a target's place is a heading or a block
;; rather than the whole file. A place names a spot inside a file somebody else
;; wrote, and this build does not splice into one: it loads the chunk in place
;; and writes nothing. The place is the symbol file, or a pair whose car is
;; heading or block — the same shape literate/targets.rkt builds.
(define (place-not-writable? place)
  (not (eq? place 'file)))

;; opaque-body-reached? answers whether a declaration name has to be read out of
;; a body the parser does not read as notation, because no registered rule
;; covers it. It is the one predicate here that takes the registered declaration
;; list as a second argument: that list lives in elements/, above this area, and
;; a predicate that asked for it itself would break the one-way dependency.
(define (opaque-body-reached? name registered-declarations)
  (not (memq name registered-declarations)))

;; write-facing-predicates lists the predicates a writer passes on its way to a
;; byte: refusing one of these stops a write that would otherwise have happened.
;; security.rkt reads it to answer state-changing? and nothing else does.
(define write-facing-predicates
  (list path-names-no-file? path-is-a-directory? path-climbs-out?
        path-is-absolute? target-names-the-document? place-not-writable?))
