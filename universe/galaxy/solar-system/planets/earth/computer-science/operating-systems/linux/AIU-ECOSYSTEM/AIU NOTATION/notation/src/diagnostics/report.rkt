#lang racket/base
;; One job: one diagnosis the reader sees — where, what, and what to do —
;; and the count and the exit code the CLI answers with.
;; Registered in plan/package-tree.org (diagnostics/report.rkt). Lands with
;; TODO item 5 (build-order step 4).
;;
;; Every line of a diagnosis comes from errors/render.rkt, the only printer of
;; an error in the package. This file holds no format string of a finding of
;; its own: a second shape would drift, and on a phone the second shape is the
;; one that wins. A finding is turned into the error record render.rkt prints,
;; and render.rkt alone turns it into a line.
;;
;; The exit code is not invented here. entry/dispatch.rkt already answers 0
;; for a clean document, 1 when something was found and 2 for a refusal (no
;; argument, no file); a report reuses exactly those, so `check` keeps one
;; meaning per code.

(require "collect.rkt"
         "../errors/err.rkt"
         "../errors/render.rkt")

(provide build-report report-text report-count report-exit-code finding-error)


;; A report is an alist, because this build has no gen:custom-write and a
;; document is the one shape the CLI, the MCP server, the skill and the plugin
;; all read:
;;
;;   (list (cons 'file f) (cons 'findings fs) (cons 'count n) (cons 'exit-code c))
;;
;; file is the file the findings are about, findings are the collected ones in
;; tree order, count is how many there are, and exit-code is the answer the
;; CLI hands back.
(define (build-report file findings)
  (list (cons 'file file)
        (cons 'findings findings)
        (cons 'count (length findings))
        (cons 'exit-code (if (null? findings) 0 1))))

;; report-text renders the findings, one line each, through render-err-list.
;; A report with nothing to say is the empty string, never a line saying that
;; there is nothing: a caller prints it or does not, and the count is the
;; report's answer either way.
(define (report-text report)
  (render-err-list (map finding-error (report-findings report))))

;; report-count is how many findings there are; report-exit-code is what the
;; CLI exits with — 0 when the count is 0, 1 when it is not. A refusal is not
;; a finding: no argument and no file are exit 2, and they are decided by the
;; command before a report exists.
(define (report-count report)
  (cdr (assq 'count report)))

(define (report-exit-code report)
  (cdr (assq 'exit-code report)))

;; finding-error is the bridge between the two areas: a finding becomes the
;; error record render.rkt prints, and it carries all four things a reader
;; must be told — who, where, what and what to do — in the record's three
;; fields, because the record has no fourth field.
(define (finding-error f)
  (make-err (finding-who f)
            (finding-place f)
            (format "~a: ~a; what to do: ~a"
                    (finding-kind f) (finding-what f) (finding-what-to-do f))))

;; finding-place says where in words: the 1-based line, and the column when
;; one could be counted. A position nobody could count reads "unknown",
;; because a wrong column sends the reader to the wrong line.
(define (finding-place f)
  (format "line ~a, column ~a"
          (finding-line f)
          (if (= (finding-column f) 0)
              "unknown"
              (number->string (finding-column f)))))

;; report-findings reads the findings back out of the report, in tree order.
(define (report-findings report)
  (cdr (assq 'findings report)))