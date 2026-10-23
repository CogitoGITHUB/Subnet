#lang racket/base
;; One job: running a program, and answering what it did — the text it
;; printed, the text it complained with, and the code it left.
;;
;; This Racket's system answers yes or no and not the code the program
;; left, so the code is asked of the shell through a file. The program
;; is named by its whole path, so nothing depends on the PATH.
;;
;; Registered in plan/package-tree.org; lands with TODO item 17.

(require racket/file
         racket/string
         racket/system
         "directories.rkt")

;; shell is the program that runs a command and tells its code.
(define shell "/bin/sh")

;; run-program runs a command through the shell and answers what it
;; did: the text it printed, the text it complained with, and the code
;; it left. A program that is not there is answered too: the code says
;; that it was not found.
;;
;; The command is given a bound: a program that hangs does not take the
;; editor down with it. The bound is the shell's timeout program, not a
;; timer in the editor: the editor does not watch anything (rule 03).
(define (run-program command seconds)
  (define out-file (build-path (state-dir) "run-out"))
  (define err-file (build-path (state-dir) "run-err"))
  (define code-file (build-path (state-dir) "run-code"))
  (ensure-dir (state-dir))
  (for ([file (in-list (list out-file err-file code-file))])
    (when (file-exists? file) (delete-file file)))
  ;; a program that breaks does not take the editor down: the break is
  ;; caught here and the answer says the program broke
  (define broke? #f)
  (with-handlers ([exn:break? (lambda (why) (set! broke? #t))])
    (system* shell "-c"
             (string-append (format "timeout ~a " seconds) command
                            " < /dev/null > '" (path->string out-file) "' 2> '" (path->string err-file)
                            "'; echo -n $? > '" (path->string code-file) "'")))
  (hash 'out (read-text out-file)
        'err (read-text err-file)
        'code (read-code code-file)
        'broke broke?))

;; read-text answers the text of a file, or nothing when the file is
;; not there.
(define (read-text path)
  (if (file-exists? path) (file->string path) ""))

;; read-code answers the code a program left, or -1 when the shell did
;; not say.
(define (read-code path)
  (if (file-exists? path)
      (or (string->number (string-trim (file->string path))) -1)
      -1))

;; shell-quote answers a text that the shell reads as one word.
(define (shell-quote text)
  (string-append "'" (string-replace text "'" "'\\''") "'"))

;; The run, for the areas above it.
(provide run-program
         shell-quote)
