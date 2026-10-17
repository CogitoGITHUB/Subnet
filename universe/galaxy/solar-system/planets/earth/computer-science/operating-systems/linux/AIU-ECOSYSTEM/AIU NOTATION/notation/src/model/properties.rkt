#lang racket/base
;; One job: tags, properties, planning states on nodes.
;; Registered in plan/package-tree.org (model/properties.rkt). Lands with TODO
;; item 3.
;;
;; Everything here comes from a declaration line, and every declaration is a
;; **hint**, never meaning (syntax/first-slice-freeze.org, rule B). A tag read
;; here may inform a reader; it may never change what an element is.

(require "nodes.rkt"
         "../errors/raise.rkt")

;; The registered declaration keywords. A line whose keyword is not here is
;; content, not a property.
(define property-keywords
  '(tags language style theme color format font))

;; parse-tags reads the value of a tags declaration: whitespace-separated
;; words, in the order written. An empty value is an empty list, never a list
;; holding an empty name.
(define (parse-tags value)
  (filter (lambda (s) (> (string-length s) 0))
          (string-split (string-trim value) " " #:trim? #t #:repeat? #t)))

;; property-of reads one property of a node by keyword. It returns the value as
;; written, or #f when the node does not carry that keyword. A keyword nobody
;; registered is refused rather than read, so no file invents a property.
(define (property-of node keyword)
  (unless (memq keyword property-keywords)
    (raise-err 'properties "properties.rkt"
               (format "~a is not a registered property keyword; use one of ~a"
                       keyword property-keywords)))
  #f)

;; tags-of is the one property a reader asks for by name, because tags are the
;; only Tier 1 declaration with a defined shape (rule C: the title's tags live
;; in its tags declaration).
(define (tags-of node)
  #f)

;; planning-state-of is named here so the reader test passes and nobody has to
;; guess where planning states will live; it is Tier 2 and returns #f until the
;; owner opens it. It decides nothing today.
(define (planning-state-of node)
  #f)