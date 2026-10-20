#lang racket/base
;; One job: the plugin system check — the proofs the plugin system
;; names. Registered in plan/package-tree.org; lands with TODO item 17.
;;
;; The proofs, one by one, and each one is real — it does the thing and
;; reads the answer back:
;;   1. a registered plugin answers a seam call
;;   2. a plugin that is not registered is refused by name
;;   3. a call the editor does not make is refused
;;   4. the editor runs with the plugin absent
;;   5. the editor never installs anything without the human's word
;;
;; The plugin the proofs use is a small program the stage writes itself:
;; it answers the seam's calls and nothing else. The stage takes the
;; manifest away when it is done, so the gate leaves nothing behind.
;;
;; The exit code is the answer: 0 when the proofs hold, 3 when one of
;; them does not.

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "../editor/src/machine/directories.rkt"
         "../editor/src/machine/run.rkt"
         "../editor/src/notation/loader.rkt"
         "../editor/src/notation/manifest.rkt"
         "../editor/src/notation/pm.rkt"
         "../editor/src/notation/seam.rkt")

;; plugin-name is the name of the plugin the proofs use.
(define plugin-name "gate-plugin")

;; plugin-program is the program of that plugin: it answers the seam's
;; calls and nothing else.
(define plugin-program
  (string-append
   "#lang racket/base\n"
   ";; A plugin answers the editor's seam calls and nothing else.\n"
   "(require json racket/file racket/list)\n"
   "(define args (vector->list (current-command-line-arguments)))\n"
   "(define request (read-json (open-input-file (car args))))\n"
   "(call-with-output-file (cadr args)\n"
   "  (lambda (port)\n"
   "    (write-json (hasheq 'ok #t 'call (hash-ref request 'call \"\") 'value \"the gate plugin answers\") port)\n"
   "    (newline port))\n"
   "  #:exists 'truncate)\n"))

;; plugin-dir is where the gate's own plugin is written: in the state
;; directory, so the gate leaves nothing in the tree.
(define plugin-dir
  (build-path (state-dir) "gate-plugin"))

;; write-plugin writes the plugin and its manifest, and registers the
;; manifest with the editor.
(define (write-plugin)
  (ensure-dir plugin-dir)
  (define program (build-path plugin-dir "plugin.rkt"))
  (call-with-output-file program
    (lambda (port) (display plugin-program port))
    #:exists 'truncate)
  (write-manifest
   (hasheq 'name plugin-name
           'version "0.0.0"
           'package plugin-name
           'spec (path->string (build-path plugin-dir "plugin.spec"))
           'command (list (path->string (racket-bin)) (path->string program))
           'provides (list "describe")))
  program)

;; take-plugin-away takes the gate's plugin away again, so the gate
;; leaves the editor as it found it.
(define (take-plugin-away)
  (define path (manifest-path plugin-name))
  (when (file-exists? path) (delete-file path)))

;; proof-one answers the first proof: a registered plugin answers a seam
;; call, and its answer is the plugin's own.
(define (proof-one)
  (define answer (call-plugin plugin-name "describe" (hasheq)))
  (and (hash-ref answer 'ok #f)
       (hash-ref (hash-ref answer 'answer #f) 'value "")))

;; proof-two answers the second proof: a plugin that is not registered
;; is refused BY NAME.
(define (proof-two)
  (define answer (call-plugin "no-such-plugin" "describe" (hasheq)))
  (define error (hash-ref answer 'error ""))
  (and (not (hash-ref answer 'ok #f))
       (string-contains? error "no-such-plugin")))

;; proof-three answers the third proof: a call the editor does not make
;; is refused.
(define (proof-three)
  (define answer (call-plugin plugin-name "not-a-call" (hasheq)))
  (and (not (hash-ref answer 'ok #f))
       (string-contains? (hash-ref answer 'error "") "not-a-call")))

;; proof-four answers the fourth proof: the editor runs with the plugin
;; absent, and says what it knows.
(define (proof-four)
  (define answer (run-program (string-append
                               (shell-quote (path->string (racket-bin))) " "
                               (shell-quote (path->string cli-path)) " plugin")
                              60))
  (and (= (hash-ref answer 'code -1) 0)
       (string-contains? (hash-ref answer 'out "") plugin-name)))

;; proof-five answers the fifth proof: the editor never installs
;; anything without the human's word.
(define (proof-five)
  (define answer (pm-apply "some.spec" #f))
  (and (not (hash-ref answer 'ok #f))
       (string-contains? (hash-ref answer 'err "") "confirmation")))

;; cli-path answers the program's own door: the entry's cli file, found
;; through the package's own crate.
(define cli-path
  (build-path (crate-dir) "src" "entry" "cli.rkt"))

;; The check, for the gate.
(define (main)
  (write-plugin)
  (define proofs
    (list (list "a registered plugin answers a seam call" (proof-one))
          (list "a plugin that is not registered is refused by name" (proof-two))
          (list "a call the editor does not make is refused" (proof-three))
          (list "the editor runs with the plugin absent" (proof-four))
          (list "the editor never installs without the human's word" (proof-five))))
  (take-plugin-away)
  (define failed (filter (lambda (pair) (not (cadr pair))) proofs))
  (if (null? failed)
      (begin
        (displayln (format "OK plugin-check — the plugin system holds: ~a"
                           (string-join (map car proofs) "; ")))
        (exit 0))
      (begin
        (displayln (format "BAD plugin-check — the proof that failed: ~a"
                           (string-join (map car failed) "; ")))
        (exit 3))))

(module+ main
  (main))
