#lang racket/base
;; One job: the error record — what happened, who, where, and what to do.
;; Registered in plan/package-tree.org; lands with TODO item 1.
;;
;; The record decides nothing and raises nothing: raise.rkt raises it and
;; render.rkt prints it. This file only says what an error IS, so that every
;; area of this program speaks about a failure the same way.

;; err is the one error record of this program. Its fields, in order:
;;   kind       the name of the failure, a symbol: err-lock-busy, err-blank-why
;;   who        who it happened to: a person, a program or a file
;;   where      where it happened, in words a reader can act on
;;   what       what happened, in one sentence
;;   what-to-do what the reader should do next
(struct err (kind who where what what-to-do) #:transparent)

;; exn:fail:editor carries an err record as a Racket exception, so the record
;; travels whole instead of being flattened into a message.
(struct exn:fail:editor exn:fail (err) #:transparent)
