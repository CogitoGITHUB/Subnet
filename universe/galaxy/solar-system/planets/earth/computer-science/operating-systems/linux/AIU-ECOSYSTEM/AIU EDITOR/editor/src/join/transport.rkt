#lang racket/base
;; One job: the transport — one request file, one answer file, one child.
;; The child is started with three file streams: its standard output is
;; the answer file, its standard input is the request file, and its
;; standard error is the voice file. Files, not pipes, because this
;; Racket build hands a child /dev/null for every stream that is not a
;; file stream: a pipe is silent, and a silent child is worse than a loud
;; failure.
;;
;; The request and the answer are one line of JSON each, the shape in
;; protocol.rkt. The child is started with the request file and the
;; answer file as its last two arguments, so a child that reads them
;; knows where they are.

(require racket/file
         racket/port
         "protocol.rkt")

;; call-over-wire runs one child program over the file wire and answers
;; its response. When the child answers nothing, the failure named
;; err-no-response carries the exit code and what the child said, so the
;; reader is never left guessing.
(define (call-over-wire program args request [cwd (current-directory)])
  (define work (make-temporary-directory "aiu-wire-~a"))
  (dynamic-wind
    void
    (lambda ()
      (define request-path (build-path work "request.jsonl"))
      (define answer-path (build-path work "answer.jsonl"))
      (define voice-path (build-path work "voice.log"))
      (call-with-output-file request-path #:exists 'truncate
        (lambda (port) (write-message port request)))
      (define exit-code
        (parameterize ([current-directory cwd])
          (let-values ([(sub stdout-in stdin-out voice-or-false)
                        (apply subprocess
                               (append (list (open-output-file answer-path #:exists 'truncate)
                                             (open-input-file request-path)
                                             (open-output-file voice-path #:exists 'truncate)
                                             program)
                                       args
                                       (list request-path answer-path)))])
            (subprocess-wait sub))))
      (or (read-response-file answer-path)
          (response #f (hasheq 'kind "err-no-response"
                              'what (format "the meaning side closed the wire with no answer (exit ~a)" exit-code)
                              'what_to_do (format "run the child by hand and read its voice: ~a" (voice-text voice-path))))))
    (lambda () (delete-directory/files work))))

;; read-response-file reads the answer file and answers the response it
;; holds, and answers nothing when the file is not there or holds no line.
(define (read-response-file path)
  (if (file-exists? path)
      (call-with-input-file path (lambda (port) (read-response port)))
      #f))

;; voice-text reads the child's voice and answers it as text, and answers
;; the empty string when the child said nothing.
(define (voice-text path)
  (if (file-exists? path) (file->string path) ""))

;; The transport, for every area that talks over the wire.
(provide call-over-wire
         read-response-file
         voice-text)
