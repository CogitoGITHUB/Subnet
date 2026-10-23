#lang racket/base
;; One job: the seam — the calls the editor makes across the boundary
;; to a plugin, and the answers a plugin gives back.
;;
;; The seam is one request and one answer, both as JSON: the editor
;; writes the request to a file, the plugin writes the answer to a
;; file. Nothing else crosses: the plugin does not see the editor's
;; state, and the editor does not see the plugin's.
;;
;; Registered in plan/package-tree.org; lands with TODO item 17.

(require json
         racket/file
         racket/list
         racket/path
         racket/string)

;; seam-calls are the calls the editor makes across the boundary, and
;; what each one means. A plugin answers only these: a call that is not
;; here is refused by name.
(define seam-calls
  '(("describe" "the plugin says what it is and what it provides")
    ("read-file" "the plugin answers the text of a file")
    ("insert-text" "the plugin puts text into the buffer")
    ("save-file" "the plugin writes the buffer to a file")))

;; seam-call-names answers the names of the calls.
(define (seam-call-names)
  (map car seam-calls))

;; seam-known? answers whether a call is one the editor makes.
(define (seam-known? call)
  (and (member call (seam-call-names)) #t))

;; seam-meaning answers what a call means, or nothing when the call is
;; not one the editor makes.
(define (seam-meaning call)
  (define found (assoc call seam-calls))
  (if found (cadr found) #f))

;; seam-request writes the request of one call into a file: the call's
;; name and its arguments, as one JSON text.
(define (seam-request path call args)
  (ensure-place path)
  (call-with-output-file path
    (lambda (port)
      (write-json (hasheq 'call call 'args args) port)
      (newline port))
    #:exists 'truncate)
  path)

;; seam-answer reads the answer of one call from a file: what the
;; plugin did, and its value or its reason. An answer that is not
;; there is answered by name, never guessed.
(define (seam-answer path)
  (if (not (file-exists? path))
      #f
      (with-handlers ([exn:fail? (lambda (why) #f)])
        (define text (string-trim (file->string path)))
        (if (string=? text "")
            #f
            (read-json (open-input-string text))))))

;; ensure-place makes sure the directory of a path is there.
(define (ensure-place path)
  (define directory (path-only path))
  (when (not (directory-exists? directory))
    (make-directory* directory))
  path)

;; The seam, for the areas above it.
(provide seam-calls
         seam-call-names
         seam-known?
         seam-meaning
         seam-request
         seam-answer
         ensure-place)
