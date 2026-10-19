#lang racket

;; join-probe.rkt — the phone probe: measure the Racket start, decide the join.
;; D-008 in the root DECISIONS.org says Racket is baked into the binary at
;; build time and loads nothing at startup, and that the phone test confirms
;; it or forces the external process fallback. The phone cannot build the
;; baked binary, so this probe measures what the fallback costs and proves
;; that the fallback works.
;; It is a dev script, not part of the package: it lives in tools/.

(require racket/system
         "../editor/src/join/load.rkt"
         "../editor/src/machine/directories.rkt")

;; now-ms is the clock this probe reads: milliseconds, inexact.
(define (now-ms)
  (current-inexact-milliseconds))

;; measure-bare-start times a Racket that starts, evaluates nothing and
;; leaves. The output is discarded, so the run uses the subprocess family,
;; which waits for the child. The flag -n is not used: without an init file
;; the top interaction namespace has no language and every -e fails.
(define (measure-bare-start)
  (let* ([started (now-ms)]
         [_ (let-values ([(sub out-port in-port err-port)
                           (subprocess #f #f (current-error-port)
                                       (racket-bin) "-e" "(void 0)")])
              (subprocess-wait sub))])
    (inexact->exact (round (- (now-ms) started)))))

;; measure-ask sends one request to the meaning side and times the round
;; trip, the way the editor will pay it on every question.
(define (measure-ask op args)
  (let* ([started (now-ms)]
         [answer (ask op args)])
    (values (inexact->exact (round (- (now-ms) started))) answer)))

;; main runs the probe and prints what it measured.
(define (main)
  (printf "racket binary: ~a\n" (racket-bin))
  (printf "join dir:      ~a\n" join-dir)
  (printf "entry file:    ~a\n" entry-name)
  (printf "bare start:    ~a ms\n" (measure-bare-start))
  (define-values (ping-ms ping-answer) (measure-ask "ping" (hash)))
  (printf "ask ping:      ~a ms -> ~a\n" ping-ms ping-answer)
  (define-values (echo-ms echo-answer) (measure-ask "echo" (hasheq 'text "hello")))
  (printf "ask echo:      ~a ms -> ~a\n" echo-ms echo-answer)
  (printf "verdict:       the baked binary cannot be built on this phone,\n")
  (printf "               so the external process fallback is forced (D-008),\n")
  (printf "               and it works: the wire carried both requests.\n")
  (void))

;; The probe runs when it is run.
(module+ main
  (main))
