#lang racket/base
;; One job: targets as data — where a chunk may go, and the door that says no.
;; Registered in plan/package-tree.org (literate/targets.rkt). Lands with TODO
;; item 6 (build step 5, literate code).
;;
;; A target is written after into:, in one of three forms:
;;
;;   into: plan/FILE-INVENTORY.org
;;   into: plan/FILE-INVENTORY.org at heading The tree
;;   into: plan/FILE-INVENTORY.org at block literate
;;
;; The three places are the ones literate-code/targets.org names: the whole
;; file, a heading, or a block, with heading the recommended default and a
;; block the override. A path that itself holds " at " is read as the first
;; form, and this file says so rather than counting the spaces and deciding.
;;
;; A target is a path and a place. That is all it is: nothing here reads the
;; file, and nothing here writes. Whether the place can be produced is the
;; question scan.rkt reports on, and what is written is generation/'s job.
;;
;; Narration: none, and deliberately so. Reading a line of the page the caller
;; already holds is a walk and not a block (the discipline
;; diagnostics/collect.rkt sets). A target that may not be written raises, and
;; a raised error is not silence. There is no wait either: this file touches no
;; disk, so nothing in it can block.

(require racket/path
         racket/string
         "chunks.rkt"
         "../errors/raise.rkt")

(provide target-of-chunk writable-path target-label target-place-word
         whole-file-target? (struct-out target))


;; A target: the path as written, and the place inside that file. The place is
;; the symbol file for the whole file, or a pair whose car is heading or block
;; and whose cdr is the name written there.
(struct target (path place) #:transparent)

;; The word that separates the path from the place. It is named here so that no
;; other file decides where the split happens.
(define at-word " at ")


;; target-of-chunk reads the target a chunk declares, or #f when the chunk
;; declares none. A chunk with no target is a chunk that loads in place; that
;; is a case of its own, not a missing value.
(define (target-of-chunk c)
  (define value (chunk-into c))
  (if value (target-of-value value) #f))

;; target-of-value reads one written into: value. The first " at " separates
;; the path from the place; a second one is refused instead of guessed at.
(define (target-of-value value)
  (define parts (string-split value at-word #:trim? #f #:repeat? #f))
  (cond
    [(null? parts)
     (raise-err 'targets "targets.rkt"
                "an into: line reads as nothing; write a path after into:")]
    [(null? (cdr parts))
     (target (writable-path (car parts) value) 'file)]
    [(null? (cdr (cdr parts)))
     (define tail (cadr parts))
     (define place (place-of tail))
     (unless place
       (raise-err 'targets "targets.rkt"
                  (format "the place \"~a\" is not a place; write \"at heading NAME\" or \"at block NAME\" after the path" tail)))
     (target (writable-path (car parts) value) place)]
    [else
     (raise-err 'targets "targets.rkt"
                (format "\"~a\" holds \"~a\" twice; the place is read only up to the first one" at-word value))]))

;; place-of reads what follows " at ": a word and a name. The name may hold
;; spaces — a heading is a phrase — so only the first word is the place.
(define (place-of tail)
  (define trimmed (string-trim tail))
  (cond
    [(string-prefix? trimmed "heading ") (cons 'heading (string-trim (substring trimmed 8)))]
    [(string-prefix? trimmed "block ") (cons 'block (string-trim (substring trimmed 6)))]
    [else #f]))

;; writable-path is the target door. A target is content in a document and a
;; document may arrive from an agent, so the path is checked before anything is
;; written: it must name a file, it must be relative, and it may not climb out
;; of the document's own directory with "..".
;;
;; This is the small door this area owns while security/security.rkt does not
;; exist. That area is where the total predicates belong (output-safe?,
;; state-changing?), it is named in plan/package-tree.org and it lands later;
;; when it does, these four refusals are replaced by its answers, not added to.
(define (writable-path path written)
  (define clean (string-trim path))
  (cond
    [(string=? clean "")
     (raise-err 'targets "targets.rkt"
                (format "the target \"~a\" names no file; write the path after into:" written))]
    [(string-suffix? clean "/")
     (raise-err 'targets "targets.rkt"
                (format "the target \"~a\" names a directory; a target is one file" written))]
    [(for/or ([seg (string-split clean "/" #:trim? #f #:repeat? #f)])
              (string=? seg ".."))
     (raise-err 'targets "targets.rkt"
                (format "the target \"~a\" climbs out with \"..\"; a target is written inside the document's own directory"
                        written))]
    [(absolute-path? clean)
     (raise-err 'targets "targets.rkt"
                (format "the target \"~a\" is an absolute path; a target is written beside the document, not anywhere on the machine"
                        written))]
    [else clean]))

;; target-label is the target as the document wrote it, for a message: a
;; reader must be able to match the line on the page with the line on screen.
(define (target-label t)
  (define path (target-path t))
  (define place (target-place t))
  (cond
    [(eq? place 'file) (format "~a, the whole file" path)]
    [(eq? (car place) 'heading) (format "~a at heading \"~a\"" path (cdr place))]
    [else (format "~a at block \"~a\"" path (cdr place))]))

;; target-place-word is the place as a word and a name, for the content hash:
;; sending a chunk to a heading is a different act from sending it to a block,
;; so the two may never share a hash.
(define (target-place-word t)
  (define place (target-place t))
  (if (eq? place 'file)
      "whole file"
      (format "~a ~a" (car place) (cdr place))))

;; whole-file-target? says whether this run may write the target: a chunk sent
;; into a whole file replaces that file's content, which is a file notation
;; owns from then on. A heading or a block place names a place inside a file
;; somebody else wrote, and this run does not splice into it yet.
;;
;; That gap is named rather than hidden. literate-code/targets.org recommends
;; heading as the default and a block as the override, and it is a skeleton
;; page: the exact design is still the owner's. scan.rkt reports every target
;; of this kind as a finding, and a run that meets one loads the chunk in
;; place and writes nothing for it, saying so.
(define (whole-file-target? t)
;; whole-file-target? says whether a target names one whole file,
;; because this build writes whole files and not pieces.
  (eq? (target-place t) 'file))
