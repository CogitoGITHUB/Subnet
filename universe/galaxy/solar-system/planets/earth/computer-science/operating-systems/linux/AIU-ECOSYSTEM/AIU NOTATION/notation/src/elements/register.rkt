#lang racket/base
;; One job: the one table — name to meaning.
;; Registered in plan/package-tree.org (elements/register.rkt). Lands with
;; TODO item 3.
;;
;; Tier 1 has exactly three block names (syntax/first-slice-freeze.org, rule A).
;; Adding a name here is a decision for the owner, not for a build.

(require "../errors/raise.rkt")

(struct element (name kind opaque?) #:transparent)

;; The one table. Nothing else in the package may decide what a name means.
(define register
  (list
   (element 'title "a heading that names the file" #f)
   (element 'paragraph "ordinary prose, the everyday case" #f)
   (element 'code "text the parser does not read as notation" #t)))

;; known-name? answers whether a name is registered. It is the only question a
;; caller needs before it may use a name.
(define (known-name? name)
  (and (memq name (map element-name register)) #t))

;; element-for returns the registered element for a name, or #f when the name
;; is not registered. It never invents one.
(define (element-for name)
  (for/first ([e (in-list register)] #:when (eq? (element-name e) name)) e))

;; element-names lists the registered names in table order, for messages and
;; for the editor's completion list.
(define (element-names)
  (map element-name register))

;; require-known is the choke point: it raises the error a caller must report
;; when a name is not registered. The error names the unknown name and what
;; to do, because the reader can act on it.
(define (require-known name)
  (unless (known-name? name)
    (raise-err 'register "register.rkt"
               (format "\"{a}\" is not a registered block name; use one of ~a"
                       name (element-names)))))