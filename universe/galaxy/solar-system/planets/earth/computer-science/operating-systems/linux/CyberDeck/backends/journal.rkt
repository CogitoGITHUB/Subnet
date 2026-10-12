#lang racket/base
;; journal.rkt -- the resumable step journal (ENGINE.org
;; backends/journal.rkt, E-10).
;;
;; Append-only JSON Lines, one file per package identity in the state
;; dir: <state>/journal/<name>/<slot>.jsonl. Each line is one step
;; transition: {"step": name, "input": input-hash, "event":
;; "start"|"end"}. A step counts as done only when its LAST record is
;; an end whose input hash equals the current one, so a run killed
;; between steps resumes by skipping exactly the steps whose hashes
;; still match. A truncated final line (no trailing newline) is a torn
;; write: dropped, never success. Any other unparseable or misshapen
;; line is corruption and refuses with kind 'config. State comes in
;; explicitly; no HOME, no XDG, no environment reads anywhere here.

(require racket/contract/base
         racket/file
         racket/list
         racket/path
         racket/string
         json
         "../core/errors.rkt"
         "../core/verbose.rkt")

(provide
 (contract-out
  ;; string string string -> path, the package journal file
  [journal-file (-> string? string? string? path?)]
  ;; string string string string string -> void, one start line
  [journal-record-start!
   (-> string? string? string? string? string? void?)]
  ;; string string string string string -> void, one end line
  [journal-record-end!
   (-> string? string? string? string? string? void?)]
  ;; string string string string string -> boolean, done under hash
  [journal-step-done?
   (-> string? string? string? string? string? boolean?)]
  ;; string string string -> (listof cons), step to last end hash
  [journal-completions
   (-> string? string? string? (listof (cons/c string? string?)))]))

;; string -> void, identities are single path segments, never paths
(define (check-identity who v)
  (unless (and (string? v)
               (not (string=? v ""))
               (not (string-contains? v "/")))
    (raise-pm-error 'config 'journal-file "bad package identity"
                    #:fields `(("field" . ,who) ("value" . ,v)))))

;; string string string -> path
(define (journal-file state name slot)
  (check-identity "name" name)
  (check-identity "slot" slot)
  (build-path state "journal" name (string-append slot ".jsonl")))

;; string string string string string string -> void, one line
(define (journal-append! state name slot step-id input event)
  (define path (journal-file state name slot))
  (make-directory* (or (path-only path) state))
  (define line
    (jsexpr->string (hasheq 'step step-id 'input input 'event event)))
  ;; D-036: the journal IS the resume record, so every line it takes is
  ;; also an event. One choke point covers start and end.
  (step 'journal
        (string-append step-id " -> " event)
        "the plan's step reached this point under this input hash"
        #:how (path->string path)
        #:inputs (list input))
  (call-with-output-file path
    (lambda (out) (displayln line out))
    #:exists 'append))

;; string string string string string -> void
(define (journal-record-start! state name slot step-id input)
  (journal-append! state name slot step-id input "start"))

;; string string string string string -> void
(define (journal-record-end! state name slot step-id input)
  (journal-append! state name slot step-id input "end"))

;; string -> jsexpr, complete lines only; anything else is config
(define (parse-line path line)
  (define js
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (raise-pm-error
                        'config 'journal-step-done?
                        "unparseable journal line"
                        #:fields `(("file" . ,(path->string path))
                                    ("line" . ,line))))])
      (string->jsexpr line)))
  (define step (and (hash? js) (hash-ref js 'step #f)))
  (define input (and (hash? js) (hash-ref js 'input #f)))
  (define event (and (hash? js) (hash-ref js 'event #f)))
  (unless (and (string? step) (string? input)
               (or (equal? event "start") (equal? event "end")))
    (raise-pm-error 'config 'journal-step-done?
                    "misshapen journal line"
                    #:fields `(("file" . ,(path->string path))
                                ("line" . ,line))))
  (list step input event))

;; path -> (listof list), complete transitions oldest first. Split
;; exactly (no trim, no repeat-collapse): after a trailing newline the
;; last chunk is the empty artifact, without one it is the torn write.
;; Either way the last chunk is dropped, never parsed.
(define (journal-read path)
  (if (not (file-exists? path))
      '()
      (let ([content (file->string path)])
        (if (string=? content "")
            '()
            (for/list ([line (in-list (drop-last
                                       (string-split content "\n"
                                                     #:trim? #f
                                                     #:repeat? #f)))])
              (parse-line path line))))))

;; (listof any) -> (listof any), all but the final element
(define (drop-last xs)
  (if (or (null? xs) (null? (cdr xs)))
      '()
      (cons (car xs) (drop-last (cdr xs)))))

;; string string string -> (listof list), shared reader for queries
(define (journal-transitions state name slot)
  (journal-read (journal-file state name slot)))

;; (listof list) -> (listof cons), ends set, starts invalidate
(define (fold-completions records)
  (let loop ([rest records] [done '()])
    (cond [(null? rest) (reverse done)]
          [else
           (define step (first (car rest)))
           (define input (second (car rest)))
           (define event (third (car rest)))
           (define kept (filter (lambda (p)
                                  (not (equal? (car p) step)))
                                done))
           (loop (cdr rest)
                 (if (equal? event "end")
                     (cons (cons step input) kept)
                     kept))])))

;; string string string -> (listof cons), step to last end hash
(define (journal-completions state name slot)
  (fold-completions (journal-transitions state name slot)))

;; string string string string string -> boolean
(define (journal-step-done? state name slot step input)
  (define hit (assoc step (journal-completions state name slot)))
  (and hit (equal? (cdr hit) input) #t))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/string
           "../core/errors.rkt")

  ;; All fixtures are synthetic (T-10) under one temp state dir.
  ;; Nothing reads the real home, the real XDG dirs, or the network.
  (define state-root (build-path (find-system-path 'temp-dir)
                                 "pm-journal-test"))
  (when (directory-exists? state-root)
    (delete-directory/files state-root))
  (make-directory* state-root)
  (define state (path->string state-root))

  ;; Missing journal means nothing done, never an error.
  (check-false (journal-step-done? state "pkg-alpha" "default"
                                   "fetch" "aa"))
  (check-equal? (journal-completions state "pkg-alpha" "default") '())

  ;; The journal file lives per package identity under the state dir.
  (check-true (string-suffix?
               (path->string (journal-file state "pkg-alpha" "default"))
               "journal/pkg-alpha/default.jsonl"))

  ;; Start plus end under a hash counts as done under that hash.
  (journal-record-start! state "pkg-alpha" "default" "fetch" "aa")
  (journal-record-end! state "pkg-alpha" "default" "fetch" "aa")
  (check-true (journal-step-done? state "pkg-alpha" "default"
                                  "fetch" "aa"))

  ;; A started step with no end is unfinished, never success.
  (journal-record-start! state "pkg-alpha" "default" "build" "bb")
  (check-false (journal-step-done? state "pkg-alpha" "default"
                                   "build" "bb"))

  ;; An end under another hash does not count for this one.
  (journal-record-start! state "pkg-alpha" "default" "link" "cc")
  (journal-record-end! state "pkg-alpha" "default" "link" "cc")
  (check-false (journal-step-done? state "pkg-alpha" "default"
                                   "link" "zz"))

  ;; A new start after an end reopens the step: killed on retry.
  (journal-record-start! state "pkg-alpha" "default" "again" "dd")
  (journal-record-end! state "pkg-alpha" "default" "again" "dd")
  (journal-record-start! state "pkg-alpha" "default" "again" "dd")
  (check-false (journal-step-done? state "pkg-alpha" "default"
                                   "again" "dd"))

  ;; Completions hold exactly the steps whose last record is an end.
  (define comps (journal-completions state "pkg-alpha" "default"))
  (check-equal? (assoc "fetch" comps) '("fetch" . "aa"))
  (check-equal? (assoc "link" comps) '("link" . "cc"))
  (check-false (assoc "build" comps))
  (check-false (assoc "again" comps))

  ;; Slots are isolated: other-slot work changes nothing here.
  (journal-record-start! state "pkg-alpha" "lts" "fetch" "aa")
  (journal-record-end! state "pkg-alpha" "lts" "fetch" "aa")
  (check-true (journal-step-done? state "pkg-alpha" "lts" "fetch" "aa"))
  (check-false (assoc "lts" comps))

  ;; A torn tail (bytes without their newline) drops silently: the
  ;; torn step is unfinished, earlier completions still report.
  (call-with-output-file (journal-file state "pkg-alpha" "default")
    (lambda (out) (display "{\"step\":\"torn\"," out))
    #:exists 'append)
  (check-false (journal-step-done? state "pkg-alpha" "default"
                                   "torn" "tt"))
  (check-true (journal-step-done? state "pkg-alpha" "default"
                                  "fetch" "aa"))

  ;; A corrupt middle line (complete but not JSON) refuses: config.
  (define corrupt (build-path state-root "corrupt.jsonl"))
  (call-with-output-file corrupt
    (lambda (out)
      (displayln "{\"step\":\"a\",\"input\":\"h\",\"event\":\"end\"}" out)
      (displayln "this is not json" out)
      (displayln "{\"step\":\"b\",\"input\":\"h\",\"event\":\"end\"}" out))
    #:exists 'truncate/replace)
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (journal-read corrupt)
                'no-error))

  ;; Valid JSON with the wrong shape refuses too: config.
  (call-with-output-file corrupt
    (lambda (out) (displayln "[1,2]" out))
    #:exists 'truncate/replace)
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (journal-read corrupt)
                'no-error))
  (delete-directory/files state-root))
