#lang racket

;; load.rkt — where the meaning side is reached; the one call that asks it.
;; The meaning side is the Racket program in racket-entry.rkt. D-008 in the
;; root DECISIONS.org says Racket is baked into the binary and loads nothing
;; at startup, and that the phone test confirms it or forces the external
;; process fallback. The phone cannot bake a binary, so the meaning side
;; runs as an external process and speaks one line of JSON per message over
;; the wire in protocol.rkt.
;;
;; THE WIRE IS A PAIR OF FILES, and that is a fact of this Racket build, not
;; a choice: a pipe handed to a child process here is turned into /dev/null
;; by racket/system (if-stream-out and if-stream-in answer #f for anything
;; that is not a file stream), so a child that is given a pipe is mute. A
;; file stream is passed straight through, so the request goes in as a file
;; the child reads and the answer comes out as a file the parent reads. The
;; shape of a message does not change: one line of JSON each way.
;;
;; Requires: the wire below, the errors floor, the machine seam.

(require racket/file
         racket/port
         racket/runtime-path
         "protocol.rkt"
         "../errors/raise.rkt"
         "../machine/directories.rkt")

;; entry-name is the meaning side's own file, named relative to this
;; directory: a path that holds a space cannot be opened from the command
;; line, so the child is started in this directory and the name stays short.
(define entry-name "racket-entry.rkt")

;; join-dir is the directory this module lives in: the child is started
;; there, so the child's own relative requires resolve. The load relative
;; directory is #f for a module reached this way, so the runtime path
;; speaks instead.
(define-runtime-path join-dir ".")

;; read-response-file reads the answer the meaning side wrote into its
;; response file. It answers #f when there is no file or no line in it.
(define (read-response-file path)
  (if (file-exists? path)
      (call-with-input-file path
        (lambda (port)
          (read-response port)))
      #f))

;; voice-text reads the child's own words: the stderr of the meaning side
;; lands in a file, so a failure can say what the child said and not only
;; that it said nothing.
(define (voice-text path)
  (if (file-exists? path)
      (file->string path)
      ""))

;; ask sends one request to the meaning side and returns its response.
;; The wire carries one line each way, through two files in a work
;; directory that is removed when the exchange is done. The child's voice
;; goes to a third file, so the response line is never mixed with a log
;; line.
(define (ask op args)
  (define work (make-temporary-directory "aiu-join-~a"))
  (dynamic-wind
    void
    (lambda ()
      (define request-path (build-path work "request.jsonl"))
      (define response-path (build-path work "response.jsonl"))
      (define voice-path (build-path work "voice.log"))
      (call-with-output-file request-path
        #:exists 'truncate
        (lambda (port)
          (write-request port op args)))
      (define exit-code
        (parameterize ([current-directory join-dir])
          (let-values ([(sub out-port in-port err-port)
                        (subprocess (open-output-file response-path #:exists 'truncate)
                                    (open-input-file request-path)
                                    (open-output-file voice-path #:exists 'truncate)
                                    (racket-bin)
                                    entry-name)])
            (subprocess-wait sub))))
      (define answer (read-response-file response-path))
      (or answer
          (response #f (hasheq 'kind "err-no-response"
                              'what (format "the meaning side answered nothing and left ~a" exit-code)
                              'what_to_do (format "run racket-entry.rkt by hand and read its voice: ~a"
                                                  (voice-text voice-path))))))
    (lambda ()
      (delete-directory/files work))))

;; Where the meaning side lives and how it is asked.
(provide ask
        entry-name
        join-dir)
