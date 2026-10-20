#lang racket/base
;; One job: rebuild the state after a crash; never guesses silently.
;; The state of an editing session lives in two places: the file holds the
;; text that was saved, and the journal holds every edit that was not saved
;; yet (rule 01). A crash loses neither, because the journal is written as
;; the edit happens. So the state is rebuilt by putting the journal's edits
;; back on top of the file.
;;
;; The text is the hot path's, so the hot path does the rebuild. This file
;; asks for it and reports exactly what it is told. A refusal is reported
;; as a refusal: this file never guesses what the state is.
;;
;; The report is one line: the counts and the journal's records. The text
;; itself is what the show command answers.
;;
;; Requires: the seam below, for the one call that asks the hot path.

(require racket/list
         racket/string
         "../join/protocol.rkt"
         "../join/hot-path.rkt")

;; replay-state asks the hot path to rebuild the state of one file from the
;; file and the journal, and answers the response. The response carries the
;; rebuilt text, the pending count and the journal's records.
(define (replay-state file journal)
  (ask-hot "replay" (hasheq 'file (path->string file)
                            'journal (path->string journal))))

;; key<? orders two names of the answer, whether they are symbols or
;; strings: the answer's names come back as symbols and the text says
;; them as they are.
(define (key<? a b)
  (string<? (if (symbol? a) (symbol->string a) a)
            (if (symbol? b) (symbol->string b) b)))

;; replay-report turns one response into one line of text: what the rebuilt
;; state measures and what is still waiting to be saved. A refusal says what
;; the hot path refused, and says nothing about the state, because the
;; state is not known.
(define (replay-report answer)
  (define data (response-data answer))
  (define pairs
    (for/list ([key (sort (hash-keys data) key<?)]
               #:unless (eq? key 'text))
      (format "~a=~a" key (hash-ref data key))))
  (if (response-ok answer)
      (string-join pairs " ")
      (string-append "FAIL " (string-join pairs " "))))

;; The rebuild, for the areas above this one.
(provide replay-state
         replay-report)
