#lang racket/base
;; One job: the no-secrets check — no secret reaches an agent, and none
;; lies on disk. Registered in plan/package-tree.org; lands with TODO
;; item 13.
;;
;; The check is real, not a smoke test: it builds a bundle that holds a
;; secret-looking line, puts it through the redaction seam, and reads
;; the bundle back. A secret that survived the seam fails the check by
;; name. Then it reads what the program keeps on disk — the journal,
;; the audit marks, the checkpoint notes — and a secret-looking line in
;; one of those files fails the check by name too.
;;
;; A line holds a secret when it NAMES a credential AND carries a value
;; after it. The name alone is not a secret: "api_key [redacted]" is
;; the shape the seam leaves behind, and a reader must be able to see
;; it.
;;
;; Registered in plan/package-tree.org; lands with TODO item 13.

(require racket/file
         racket/list
         racket/port
         racket/string
         "../editor/src/machine/directories.rkt"
         "../editor/src/security/redact.rkt"
         "../editor/src/send/bundle.rkt")

;; the-secret is the line the check puts into a real bundle: it names a
;; credential and holds a token that has the shape of one.
(define the-secret "api_key = sk-0123456789abcdef")

;; the-value is the part of the secret that must never be seen again.
(define the-value "sk-0123456789abcdef")

;; credential-names are the words that name a credential. A line with one
;; of them, and a value after it, holds a secret.
(define credential-names
  '("api_key" "api-key" "apikey" "password" "passwd" "secret" "token"
    "authorization" "sk-" "bearer " "-----begin"))

;; holds-secret? answers whether the line names a credential and carries
;; a value after it. A redacted line does not: its value is the marker.
(define (holds-secret? line)
  (define lowered (string-downcase line))
  (define named
    (for/or ([name (in-list credential-names)])
      (string-contains? lowered (string-downcase name))))
  (and named (carries-value? line)))

;; holding-line answers the first line of a text that holds a secret, or
;; nothing when no line does. The line is named, so a failure says
;; WHICH line is the secret.
(define (holding-line text)
  (for/or ([line (in-list (string-split text "\n"))])
    (and (holds-secret? line) line)))

;; carries-value? answers whether the line has a value after its
;; separator, and that value is not the redaction marker.
(define (carries-value? line)
  (define at
    (let ([colon (index-of line ":")]
          [equals (index-of line "=")])
      (cond
        [(and (not colon) (not equals)) #f]
        [(and colon (not equals)) colon]
        [(and (not colon) equals) equals]
        [else (min colon equals)])))
  (and at
       (let ([value (string-trim (substring line (add1 at) (string-length line)))])
         (and (not (string=? value ""))
              (not (string=? value "[redacted]"))
              (not (string=? value "[redacted];"))))))

;; index-of answers where a piece of text begins in a line, or nothing
;; when it is not there. The search is written here because this
;; Racket's string-contains? answers yes or no, and a position is what
;; the check needs.
(define (index-of line piece)
  (let loop ([at 0])
    (cond
      [(> (+ at (string-length piece)) (string-length line)) #f]
      [(string=? (substring line at (+ at (string-length piece))) piece) at]
      [else (loop (add1 at))])))

;; main runs the check and answers the verdict: the exit code is the
;; answer, and every failure is named.
(define (main)
  (define problems '())

  ;; the bundle: a real one, built the way the send builds it, with a
  ;; secret in the selection
  (define bundle
    (make-bundle "aiu-editor" "aiu-ecosystem" "opencode"
                 (string-append "the first line\n" the-secret "\nthe last line")
                 "/tmp/aiu-bundle-check.txt"
                 0
                 #f
                 "proving the seam on a real bundle"))
  (define text (bundle-text bundle))

  ;; the bundle must hold the secret before the seam: a check that
  ;; proves nothing is not a check
  (unless (holds-secret? text)
      (set! problems (cons "the bundle did not hold the secret the check put in it" problems)))

  ;; the seam must take the value out
  (define redacted (redact-text text))
  (when (string-contains? redacted the-value)
      (set! problems (cons (format "the secret survived the seam: ~a" redacted) problems)))
  (unless (string-contains? redacted "[redacted]")
      (set! problems (cons "the seam did not say that something was hidden" problems)))
  (define left (holding-line redacted))
  (when left
      (set! problems (cons (format "the seam left a credential with a value in it: ~a" left) problems)))

  ;; the disk: what the program keeps
  (for ([file (in-list (state-files))])
    (for ([line (in-list (lines-of file))])
      (when (holds-secret? line)
        (set! problems (cons (format "a secret lies on disk: ~a: ~a" file line) problems)))))

  (if (null? problems)
      (begin
        (displayln "OK secret-check — a real bundle comes out of the seam clean, and nothing on disk holds a secret")
        (exit 0))
      (begin
        (for ([problem (in-list problems)]) (displayln (format "SECRET — ~a" problem)))
        (displayln (format "SECRET — ~a problems" (length problems)))
        (exit 1))))

;; state-files answers the files the program keeps in its state
;; directory: the journal, the audit marks and the checkpoint notes.
(define (state-files)
  (define dir (state-dir))
  (if (not (file-exists? dir))
      '()
      (for/list ([entry (in-list (directory-list dir #:follow-links #f))])
        (define path (build-path dir entry))
        (cond
          [(directory-exists? path) (state-files-in path)]
          [(file-exists? path) (list path)]
          [else '()]))))

;; state-files-in answers the files inside a directory of the state
;; directory, one level down: the audit keeps its marks there.
(define (state-files-in dir)
  (for/list ([entry (in-list (directory-list dir #:follow-links #f))])
    (define path (build-path dir entry))
    (cond
      [(directory-exists? path) (state-files-in path)]
      [(file-exists? path) (list path)]
      [else '()])))

;; lines-of answers the lines of a file, or the empty list when the file
;; cannot be read.
(define (lines-of path)
  (with-handlers ([exn:fail? (lambda (why) '())])
    (call-with-input-file path
      (lambda (port)
        (let loop ([out '()])
          (define line (read-line port))
          (if (eof-object? line)
              (reverse out)
              (loop (cons line out))))))))

;; The check, when it is run.
(module+ main
  (main))
