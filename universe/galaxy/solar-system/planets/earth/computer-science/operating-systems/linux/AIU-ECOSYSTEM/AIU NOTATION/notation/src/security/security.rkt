#lang racket/base
;; One job: the refusals as data — every rule this format has, by id.
;; Registered in plan/package-tree.org (security/security.rkt): "the total
;; predicates: output-safe?, state-changing?, refusals". Lands with TODO item 1
;; (the tree lands).
;;
;; A rule is a row of four: the id that says what is refused, the predicate that
;; decides it, what it refuses, and what the reader may do instead. It is data,
;; not code that runs — this file decides nothing and refuses nothing, so a
;; reader may enumerate every rule and look one up by id without running one
;; check. refuse.rkt is the only door that makes a refusal.
;;
;; Every id here points at a real check. Four are literate/targets.rkt's
;; writable-path door, one is whole-file-target? there, one is
;; generation/write.rkt's require-replaceable, and one is literate/chunks.rkt
;; reading a chunk header out of a body the parser does not read as notation.
;; That last one is named because it is a real gap, and a vocabulary that hides
;; a gap is not a vocabulary.

(require "shapes.rkt")

(provide security-rules rule-by-id rule-ids state-changing?
         (struct-out security-rule))


;; A rule:
;;   id        — a symbol that says what is refused
;;   predicate — the pure question that decides it; #t refuses the value
;;   refuses   — what it refuses, in words
;;   remedy    — what the reader may do instead, in words
(struct security-rule (id predicate refuses remedy) #:transparent)

;; The rules, in the order a writer meets them: what the path is, where it
;; points, where it lands, and finally what may be read out of an opaque body.
(define security-rules
  (list
   (security-rule 'target-names-no-file
                  path-names-no-file?
                  "an into: value that names no file"
                  "write a path after into:")
   (security-rule 'target-is-a-directory
                  path-is-a-directory?
                  "a target that names a directory; a target is one file"
                  "name the one file the chunk belongs in")
   (security-rule 'path-escapes-root
                  path-climbs-out?
                  "a target that climbs out with \"..\""
                  "write the target inside the document's own directory")
   (security-rule 'absolute-target
                  path-is-absolute?
                  "a target written as an absolute path"
                  "write the target beside the document, relative to it")
   (security-rule 'target-is-the-document
                  target-names-the-document?
                  "a target that is the document itself"
                  "point the into: line at a file of its own")
   (security-rule 'unwritable-place
                  place-not-writable?
                  "a heading or block place; this build writes whole files only"
                  "send to the whole file, or leave the place to the owner")
   (security-rule 'opaque-body-reached
                  opaque-body-reached?
                  "a declaration no rule registers, read out of a code body"
                  "register the keyword as a declaration, or write the rule")))

;; rule-by-id returns the rule with that id, or #f when no rule carries it. It
;; never invents a rule and never refuses: a caller that finds #f has a typo or
;; a rule this vocabulary does not carry, and that is a different message.
(define (rule-by-id id)
  (for/first ([r (in-list security-rules)]
              #:when (eq? (security-rule-id r) id))
    r))

;; rule-ids lists every id in rule order, for a message that offers the reader
;; the whole vocabulary instead of one name.
(define (rule-ids)
  (map security-rule-id security-rules))

;; state-changing? answers whether refusing this rule stops a change of state:
;; whether its predicate is one a writer passes on the way to a byte. The answer
;; is #f for anything that is not a rule, so the predicate stays total, and #f
;; for opaque-body-reached, which governs a reading decision and writes nothing.
(define (state-changing? rule)
  (and (security-rule? rule)
       (memq (security-rule-predicate rule) write-facing-predicates)))
