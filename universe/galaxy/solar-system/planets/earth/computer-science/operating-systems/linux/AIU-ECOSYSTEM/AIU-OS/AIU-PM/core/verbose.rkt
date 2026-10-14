#lang racket/base
;; verbose.rkt -- the ONE narration path (D-036). Every operation says
;; what it is doing, why, how, when (UTC) and how long (monotonic), and
;; every event goes to three places: the screen line, a JSON Lines file
;; under <state>/events/, and the AI feed, which is that same JSON Lines
;; file. There is no fourth format and no second copy.
;;
;; Hard rules, enforced here rather than by convention:
;;   - why is MANDATORY for step, decide, skip and a failing with-op.
;;     No reason is a bug, and it raises.
;;   - nothing can switch this off. D-021's PM_TRACE=0 silenced the
;;     screen; D-036 supersedes that. The parameter below exists for
;;     tests only and is never read from the environment.
;;   - the package manager NEVER waits for a reader. The feed is a file;
;;     a missing AI changes nothing.
;;
;; Pure except for emit: with-op returns whatever its thunk returned,
;; and the only effect is the three destinations. No timers, no polling,
;; no hidden discards.

(require racket/contract/base
         racket/file
         racket/format
         racket/list
         racket/path
         racket/port
         racket/string
         json
         "errors.rkt"
         "log.rkt"
         "scope.rkt")

(provide
 (struct-out verbose-run)
 (contract-out
  ;; (-> void) -> string, open a run and return its id
  [begin-run! (->* () (#:who symbol?
                           #:events-dir (or/c path-string? path? #f))
                    string?)]
  ;; any -> void, close the active run with this result
  [end-run! (-> any/c void?)]
  ;; -> string or #f, the active run id
  [current-run-id (-> (or/c string? #f))]
  ;; -> boolean, is a run open? Callers that have their own plain
  ;; stderr record (run.rkt's pm-run-*) use this to decide between
  ;; narrating into the feed and printing their legacy line, never to
  ;; print both.
  [run-open? (-> boolean?)]
  ;; string -> path, the feed file for a run, under the real events dir
  [events-file (-> path-string? path?)]
  ;; -> path, <state>/events, resolved through core/scope.rkt only
  [default-events-dir (-> path?)]
  ;; the emitting verbs
  [with-op (->* (symbol? string? string?)
                ((-> any)
                 #:how (or/c string? #f)
                 #:inputs (listof any/c))
                any)]
  [step (->* (symbol? string? string?)
             (#:how (or/c string? #f)
              #:inputs (listof any/c))
             void?)]
  [note (-> symbol? string? void?)]
  [decide (->* (symbol? string? string? #:chosen any/c)
               (#:alternatives (listof any/c))
               void?)]
  [skip (-> symbol? string? string? void?)]
  [progress (->* (symbol? string?)
                 (#:done (or/c exact-nonnegative-integer? #f)
                  #:total (or/c exact-nonnegative-integer? #f))
                 void?)]
  [warn (-> symbol? string? void?)]
  ;; Tests only: quiet the screen without touching the feed.
  [verbose-screen? (parameter/c boolean?)]))

;; ---------------------------------------------------------------------------
;; Run state

;; seq is a BOX: this Racket's struct-out exports no mutator, so
;; the one counter that moves is a box inside the struct.
(struct verbose-run (id seq-box parent depth start-ms port)
  #:transparent)

;; The active run. #f before begin-run!, or in code that never opened
;; one; events still reach the screen, because nothing is silent.
(define current-verbose-run (make-parameter #f))

;; Tests may silence the SCREEN only. The feed is never silenced: a
;; test that wants no file points begin-run! at a temp dir.
(define verbose-screen? (make-parameter #t))

;; symbol -> string, the run id: the WHO label plus the monotonic
;; start in whole milliseconds. Not a wall clock we would have to poll
;; and not random, so a run id is reproducible from the process state.
(define (make-run-id who)
  (string-append (symbol->string who)
                 "-"
                 (number->string (mono-ms))))

;; -> path, <state>/events. Only core/scope.rkt reads HOME or XDG_*.
(define (default-events-dir)
  (build-path (roots-data (scope-roots 'user)) "cyberdeck" "events"))

;; string -> path, the feed for RUN-ID under the real events dir
(define (events-file run-id)
  (build-path (default-events-dir) (string-append run-id ".jsonl")))

;; ---------------------------------------------------------------------------
;; Clocks. Two of them, each read once per event.

;; exact-nonnegative-integer -> string, "HH:MM:SSZ". This Racket's
;; current-seconds is whole-second, so utc is second-resolution and the
;; sub-second detail lives in mono-ms and duration-ms, which come off
;; the monotonic clock instead.
(define (utc-stamp secs)
  (define d (seconds->date secs #f))
  (define (pad n width)
    (~r n #:min-width width #:pad-string "0"))
  (string-append (pad (date-hour d) 2)
                 ":"
                 (pad (date-minute d) 2)
                 ":"
                 (pad (date-second d) 2)
                 "Z"))

;; -> exact-nonnegative-integer, whole milliseconds off the monotonic
;; clock, never wall time: a clock change cannot make a duration wrong.
(define (mono-ms)
  (inexact->exact (round (current-inexact-monotonic-milliseconds))))

;; ---------------------------------------------------------------------------
;; Redaction. ONE path, applied to every field BEFORE any destination,
;; so a password cannot leak through the screen, the feed or the log by
;; three different routes.

;; any -> string, the ONE redaction path from core/log.rkt (S-8)
(define (safe v)
  (trace-redact v))

;; (listof any) -> string, short redacted summary for an event field
(define (summary vs)
  (define s (string-join (map safe vs) " "))
  (if (> (string-length s) 120) (string-append (substring s 0 120) "...") s))

;; ---------------------------------------------------------------------------
;; Why is mandatory. A blank reason is a caller bug, not a default.

;; string string -> void, or kind 'internal
(define (require-why verb why)
  (when (or (not (string? why)) (string=? (string-trim why) ""))
    (raise-pm-error
     'internal
     'verbose
     "a reason is required"
     #:fields `(("verb" . ,verb)
                ("why" . ,(format "~s" why)))
     #:hint "every step, decide, skip and failure names why it happened")))

;; ---------------------------------------------------------------------------
;; The event record

;; kind fields run seq depth parent -> hash, one event
(define (make-event kind who what why how inputs outputs result run seq)
  (hasheq 'run-id (verbose-run-id run)
          'seq seq
          'parent-id (or (verbose-run-parent run) #f)
          'kind (symbol->string kind)
          'depth (verbose-run-depth run)
          'who (symbol->string who)
          'what (safe what)
          'why (safe why)
          'how (if how (safe how) #f)
          'inputs (map safe inputs)
          'outputs (map safe outputs)
          'result (safe result)
          'utc (utc-stamp (current-seconds))
          'mono-ms (mono-ms)
          'duration-ms (- (mono-ms) (verbose-run-start-ms run))))

;; hash -> string, the screen line. Two spaces per depth level.
(define (event->screen-line ev)
  (define indent (make-string (* 2 (hash-ref ev 'depth 0)) #\space))
  (define utc (hash-ref ev 'utc))
  (define clock (substring utc 0 (max 1 (- (string-length utc) 1))))
  (define secs (~r (/ (hash-ref ev 'duration-ms) 1000.0) #:precision 3))
  (define how (hash-ref ev 'how))
  (string-append indent
                 "[" clock " +" secs "s] "
                 (hash-ref ev 'kind) " "
                 (hash-ref ev 'who)
                 " | what: " (hash-ref ev 'what)
                 " | why: " (hash-ref ev 'why)
                 " | how: " (if how how "-")))

;; ---------------------------------------------------------------------------
;; emit: the one place an event leaves. Screen first (a human sees it
;; even if the file is unwritable), then the feed, flushed per event.

;; verbose-run -> hash, the event just emitted
(define (emit! kind who what why how inputs outputs result)
  (define run (or (current-verbose-run)
                  (verbose-run "adhoc" (box 0) #f 0 (mono-ms) #f)))
  (define seq (unbox (verbose-run-seq-box run)))
  (define ev (make-event kind who what why how inputs outputs result run seq))
  (when (verbose-screen?)
    (define err (current-error-port))
    (displayln (event->screen-line ev) err)
    (flush-output err))
  (when (verbose-run-port run)
    (define port (verbose-run-port run))
    (write-json ev port)
    (newline port)
    (flush-output port))
  (set-box! (verbose-run-seq-box run) (add1 seq))
  ev)

;; -> string or #f, "RUN#SEQ": the event a child should point at
(define (here-id)
  (define run (current-verbose-run))
  (and run (string-append (verbose-run-id run)
                          "#"
                          (number->string
                           (unbox (verbose-run-seq-box run))))))

;; ---------------------------------------------------------------------------
;; The verbs

;; who what why how inputs -> void, STEP. The public verb; WHY is not
;; optional and a blank one raises.
(define (step who what why #:how [how #f] #:inputs [inputs '()])
  (require-why 'step why)
  (emit! 'STEP who what why how inputs '() '())
  (void))

;; with-op: push depth and parent, emit START, run the thunk, emit END
;; with the result or FAIL with the error, then re-raise. Returns the
;; thunk's value; a multiple-value thunk returns its first value and
;; the END record still carries them all.
(define (with-op who what why
                #:how [how #f] #:inputs [inputs '()]
                [thunk (lambda ()
                         (raise-pm-error 'internal 'with-op
                                         "a thunk is required"
                                         #:fields '()))])
  (require-why 'with-op why)
  (define outer (current-verbose-run))
  (define parent-id (here-id))
  (define start (emit! 'START who what why how inputs '() #f))
  (define inner
    (verbose-run (if outer (verbose-run-id outer) "adhoc")
                 ;; the SAME counter box, so a nested event keeps the
                 ;; run's sequence instead of restarting at zero
                 (if outer (verbose-run-seq-box outer) (box 0))
                 (string-append (hash-ref start 'run-id)
                                "#"
                                (number->string (hash-ref start 'seq)))
                 (add1 (hash-ref start 'depth 0))
                 (mono-ms)
                 (if outer (verbose-run-port outer) #f)))
  (define failure #f)
  (define outs
    (parameterize ([current-verbose-run inner])
      (with-handlers
          ([exn:fail?
            (lambda (e)
              (set! failure (exn-message e))
              (emit! 'FAIL who what why how inputs '() failure)
              (raise e))])
        (call-with-values
         thunk
         (lambda vs (list vs))))))
  (if failure
      (void)
      (let* ([vals (car outs)]
             [single (if (pair? vals) (car vals) vals)])
        (emit! 'END who what why how inputs vals (summary vals))
        single)))

;; symbol string -> void, INFO
(define (note who what)
  (emit! 'INFO who what "record" #f '() '() '())
  (void))

;; symbol string string any (listof any) -> void, DECIDE
(define (decide who what why #:chosen chosen #:alternatives [alternatives '()])
  (require-why 'decide why)
  (emit! 'DECIDE
         who
         what
         why
         (string-append "chose " (safe chosen) " over "
                        (string-join (map safe alternatives) " "))
         (list chosen)
         alternatives
         chosen)
  (void))

;; symbol string string -> void, SKIP
(define (skip who what why)
  (require-why 'skip why)
  (emit! 'SKIP who what why #f '() '() '())
  (void))

;; symbol string -> void, WARN
(define (warn who what)
  (emit! 'WARN who what "attention" #f '() '() '())
  (void))

;; symbol string done total -> void, PROGRESS
(define (progress who what #:done [done #f] #:total [total #f])
  (emit! 'PROGRESS
         who
         what
         "progress"
         (cond [(and done total) (format "~a/~a" done total)]
               [done (number->string done)]
               [total (format "of ~a" total)]
               [else #f])
         '()
         (if done (list done) '())
         (or total '()))
  (void))

;; ---------------------------------------------------------------------------
;; Run lifecycle

;; Write-then-rename is atomic enough here: same directory, so the
;; reader either sees the old `current` or the new one, never a half
;; written file. Falls back to a copy when rename is refused.
(define (replace-file from to)
  ;; The target usually EXISTS: a second run in the same state dir
  ;; rewrites `current`. rename refuses an existing destination, so the
  ;; old one goes first; if that fails the copy still lands.
  (when (file-exists? to)
    (delete-file to))
  (with-handlers ([exn:fail:filesystem? (lambda (_) (copy-file from to))])
    (rename-file-or-directory from to)))

;; (-> void) -> string. Opens the feed, writes `current` atomically,
;; makes this the active run. A second begin-run! while one is open is
;; a caller bug and raises, so two runs never share a file.
(define (begin-run! #:who [who 'pm] #:events-dir [events-dir #f])
  (when (current-verbose-run)
    (raise-pm-error
     'internal
     'begin-run!
     "a run is already open"
     #:fields `(("run" . ,(verbose-run-id (current-verbose-run))))))
  (define dir (cond [(not events-dir) (default-events-dir)]
                  [(path? events-dir) events-dir]
                  [else (string->path events-dir)]))
  (make-directory* dir)
  (define run-id (make-run-id who))
  (define port (open-output-file (build-path dir (string-append run-id ".jsonl"))
                                #:exists 'truncate/replace))
  (current-verbose-run (verbose-run run-id (box 0) #f 0 (mono-ms) port))
  ;; current: the active run id, written then renamed, never half-written
  (define tmp (build-path dir "current.tmp"))
  (call-with-output-file tmp
    (lambda (out) (displayln run-id out))
    #:exists 'truncate/replace)
  (replace-file tmp (build-path dir "current"))
  (emit! 'START who "run" "session start" #f '() '() run-id)
  run-id)

;; any -> void, emit END for the run and close the feed
(define (end-run! result)
  (define run (current-verbose-run))
  (unless run
    (raise-pm-error 'internal 'end-run! "no run is open" #:fields '()))
  (emit! 'END 'run "run" "session end" #f '() (list result) result)
  (close-output-port (verbose-run-port run))
  (current-verbose-run #f))

;; -> string or #f, the active run id
(define (current-run-id)
  (define run (current-verbose-run))
  (and run (verbose-run-id run)))

;; -> boolean
(define (run-open?)
  (and (current-verbose-run) #t))
;; ---------------------------------------------------------------------------


(module+ test
  (require rackunit
           racket/file
           racket/list
           racket/string
           json)

  ;; Everything lands under one temp root; nothing reads the real home
  ;; or XDG. Cases silence the SCREEN only and assert on the feed.
  (define root
    (build-path (find-system-path 'temp-dir) "pm-verbose-test"))
  (when (directory-exists? root)
    ;; Regression: `current` already exists on the SECOND run in the same
  ;; state dir, and a rename refuses an existing destination. Both runs
  ;; must succeed and `current` must name the newer one.
  (define shared (build-path root "shared"))
  (make-directory* shared)
  (parameterize ([verbose-screen? #f])
    (define id1 (begin-run! #:who 'test #:events-dir shared))
    (end-run! "first")
    (define id2 (begin-run! #:who 'test #:events-dir shared))
    (end-run! "second")
    (check-not-false (string? id2))
    (check-equal? (string-trim (file->string (build-path shared "current")))
                  id2))

  (delete-directory/files root))
  (make-directory* root)

  (define counter 0)

  ;; (-> void) -> path, a fresh empty events dir for one case
  (define (fresh-dir)
    (set! counter (add1 counter))
    (define d (build-path root (format "run-~a" counter)))
    (make-directory* d)
    d)

  ;; path -> string, every feed file in DIR, concatenated
  (define (feed-text dir)
    (for/fold ([acc ""])
              ([f (in-list (directory-list dir))]
               #:when (regexp-match? #rx"\\.jsonl$" f))
      (string-append acc (file->string (build-path dir f)))))

  ;; path -> (listof hash), every event parsed back from the feed
  (define (feed-events dir)
    (for/list ([l (in-list (string-split (feed-text dir) "\n"))]
               #:unless (string=? (string-trim l) ""))
      (read-json (open-input-string l))))

  ;; path -> (listof string), the kinds in order
  (define (feed-kinds dir)
    (map (lambda (e) (hash-ref e 'kind)) (feed-events dir)))

  ;; --- START before END, nothing lost -----------------------------------
  (define d1 (fresh-dir))
  (define v1
    (parameterize ([verbose-screen? #f])
      (begin-run! #:who 'test #:events-dir d1)
      (define r
        (with-op 'fetch "pkg-alpha" "to test start and end"
                 #:inputs '("pkg-alpha")
                 (lambda ()
                   (note 'fetch "midway")
                   "fetched")))
      (end-run! "done")
      r))
  (check-equal? v1 "fetched")
  (define kinds1 (feed-kinds d1))
  (check-equal? (car kinds1) "START")
  (check-equal? (last kinds1) "END")
  (check-not-false (member "INFO" kinds1))
  ;; every JSON line parsed: feed-events would have raised otherwise
  (check-equal? (length (feed-events d1))
                (length (filter (lambda (s)
                                  (not (string=? (string-trim s) "")))
                                (string-split (feed-text d1) "\n"))))

  ;; --- a failing op emits FAIL and re-raises ----------------------------
  (define d2 (fresh-dir))
  (define caught
    (parameterize ([verbose-screen? #f])
      (begin-run! #:who 'test #:events-dir d2)
      (define c
        (with-handlers ([exn:fail? (lambda (e) e)])
          (with-op 'build "compile" "to test failure"
                   (lambda ()
                     (raise (exn:fail "boom" (current-continuation-marks)))))
          'no-error))
      (end-run! "failed on purpose")
      c))
  (check-true (exn:fail? caught))
  (define fail-event
    (for/first ([e (in-list (feed-events d2))]
                #:when (equal? (hash-ref e 'kind) "FAIL"))
      e))
  (check-true (and fail-event (regexp-match? #rx"boom"
                                           (hash-ref fail-event 'result))))
  (check-equal? (last (feed-kinds d2)) "END")

  ;; --- why is required, and a blank one raises --------------------------
  (define d3 (fresh-dir))
  (parameterize ([verbose-screen? #f])
    (begin-run! #:who 'test #:events-dir d3)
    (check-exn exn:fail:pm? (lambda () (step 'plan "x" "")))
    (check-exn exn:fail:pm? (lambda () (step 'plan "x" "   ")))
    (check-exn exn:fail:pm? (lambda () (skip 'plan "x" "")))
    (check-exn exn:fail:pm? (lambda () (decide 'plan "x" "" #:chosen 'a)))
    (check-exn exn:fail:pm?
               (lambda () (with-op 'plan "x" "" (lambda () 1))))
    (end-run! "done"))
  (check-equal? (last (feed-kinds d3)) "END")

  ;; --- redaction: the secret reaches no destination ---------------------
  (define d4 (fresh-dir))
  (parameterize ([verbose-screen? #f])
    (begin-run! #:who 'test #:events-dir d4)
    (step 'fetch "url" "redaction check"
          #:how "https://user:s3cret@example.invalid/a.tgz"
          #:inputs '("https://user:s3cret@example.invalid/a.tgz"))
    (end-run! "done"))
  (define text4 (feed-text d4))
  (check-false (regexp-match? #rx"s3cret" text4))
  (check-true (regexp-match? #rx"://[*][*][*]@" text4))

  (define err4 (open-output-string))
  (parameterize ([verbose-screen? #t]
                 [current-error-port err4])
    (begin-run! #:who 'test #:events-dir (fresh-dir))
    (step 'fetch "url" "screen redaction"
          #:how "https://user:s3cret@example.invalid/a.tgz")
    (end-run! "done"))
  (check-false (regexp-match? #rx"s3cret" (get-output-string err4)))

  ;; --- nesting depth and parent ids -------------------------------------
  (define d5 (fresh-dir))
  (parameterize ([verbose-screen? #f])
    (begin-run! #:who 'test #:events-dir d5)
    (with-op 'apply "outer" "nesting check"
             (lambda ()
               (with-op 'build "inner" "nested operation"
                        (lambda ()
                          (step 'build "leaf" "leaf step")))))
    (end-run! "done"))
  (define ev5 (feed-events d5))
  (define depths5 (map (lambda (e) (hash-ref e 'depth)) ev5))
  (check-not-false (member 0 depths5))
  (check-not-false (member 1 depths5))
  (check-not-false (member 2 depths5))
  (define nested-start
    (for/first ([e (in-list ev5)]
                #:when (and (equal? (hash-ref e 'kind) "START")
                            (= 1 (hash-ref e 'depth))))
      e))
  (check-true (string? (hash-ref nested-start 'parent-id)))
  (define leaf
    (for/first ([e (in-list ev5)]
                #:when (and (equal? (hash-ref e 'kind) "STEP")
                            (= 2 (hash-ref e 'depth))))
      e))
  (check-true (string? (hash-ref leaf 'parent-id)))
  (check-false (equal? (hash-ref leaf 'parent-id)
                       (hash-ref nested-start 'parent-id)))
  ;; nested events keep the run's sequence, not a fresh counter
  (define seqs5 (map (lambda (e) (hash-ref e 'seq)) ev5))
  (check-equal? seqs5 (sort seqs5 <))

  ;; --- every event carries the full field set ---------------------------
  (define required-keys
    '(run-id seq parent-id kind depth who what why how inputs
             outputs result utc mono-ms duration-ms))
  (for ([e (in-list ev5)])
    (for ([k (in-list required-keys)])
      (check-true (hash-has-key? e k) (format "event missing ~a" k))))

  ;; --- an exception passing through still closes the run ---------------
  (define d6 (fresh-dir))
  (parameterize ([verbose-screen? #f])
    (begin-run! #:who 'test #:events-dir d6)
    (with-handlers ([exn:fail? void?])
      (with-op 'update "all" "throws on purpose"
               (lambda ()
                 (raise (exn:fail "mid-fail" (current-continuation-marks))))))
    (end-run! "done"))
  (check-not-false (member "FAIL" (feed-kinds d6)))
  (check-equal? (last (feed-kinds d6)) "END")
  (check-false (current-run-id))

  ;; --- progress, decide, skip and warn all land -------------------------
  (define d7 (fresh-dir))
  (parameterize ([verbose-screen? #f])
    (begin-run! #:who 'test #:events-dir d7)
    (decide 'resolve "source" "the spec pins a commit"
            #:chosen "git+commit"
            #:alternatives '("tarball"))
    (progress 'fetch "bytes" #:done 3 #:total 9)
    (warn 'fetch "slow mirror")
    (skip 'build "configure" "no configure step in the spec")
    (end-run! "done"))
  (define kinds7 (feed-kinds d7))
  (for ([k (in-list '("DECIDE" "PROGRESS" "WARN" "SKIP"))])
    (check-not-false (member k kinds7) (format "~a missing" k)))

  ;; --- the screen line is golden-comparable -----------------------------
  ;; Narration goes to the ERROR port, so that is what is captured
  ;; here; capturing stdout would silently see nothing.
  (define err8 (open-output-string))
  (parameterize ([verbose-screen? #t]
                 [current-error-port err8])
    (begin-run! #:who 'test #:events-dir (fresh-dir))
    (with-op 'plan "specs" "golden check"
             (lambda ()
               (step 'plan "read" "reading specs")
               1))
    (end-run! "done"))
  (define screen (get-output-string err8))
  (define lines
    (filter (lambda (l) (regexp-match? #rx"^ *\\[" l))
            (string-split screen "\n")))
  ;; plain string assertions: no regex escaping to get wrong
  (define (indent-of l)
    (let loop ([n 0])
      (cond [(and (< n (string-length l))
                  (char=? (string-ref l n) #\space))
             (loop (add1 n))]
            [else n])))
  (check-equal? (length lines) 5)
  (check-true (string-contains? (car lines) "START test"))
  (check-true (string-contains? (car lines) "why: session start"))
  (define start-line
    (for/first ([l (in-list lines)] #:when (string-contains? l "what: specs"))
      l))
  (define step-line
    (for/first ([l (in-list lines)] #:when (string-contains? l "what: read"))
      l))
  (check-true (string-contains? start-line "why: golden check"))
  (check-true (string-contains? step-line "why: reading specs"))
  ;; a nested event is indented two spaces more than its parent
  (check-equal? (indent-of step-line) (+ 2 (indent-of start-line)))

  ;; Regression: `current` already exists on the SECOND run in the same
  ;; state dir, and a rename refuses an existing destination. Both runs
  ;; must succeed and `current` must name the newer one.
  (define shared (build-path root "shared"))
  (make-directory* shared)
  (parameterize ([verbose-screen? #f])
    (define id1 (begin-run! #:who 'test #:events-dir shared))
    (end-run! "first")
    (define id2 (begin-run! #:who 'test #:events-dir shared))
    (end-run! "second")
    (check-not-false (string? id2))
    (check-equal? (string-trim (file->string (build-path shared "current")))
                  id2))

  (delete-directory/files root))
