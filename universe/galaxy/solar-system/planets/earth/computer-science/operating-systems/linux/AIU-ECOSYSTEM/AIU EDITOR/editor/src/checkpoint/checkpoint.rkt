#lang racket/base
;; One job: the checkpoint — the state the tree is put back to when an
;; agent does something the human did not want. Registered in
;; plan/package-tree.org; lands with TODO item 12.
;;
;; A checkpoint is made BEFORE an agent acts, not after: that is the
;; whole point of it. The checkpoint is a git commit of the tracked files
;; and a note of what was not tracked, so the rollback can put the tree
;; back exactly as it was.
;;
;; The commit is made with the tree's own files, one by one — never a
;; blanket add, because a blanket add sweeps in whatever happens to be
;; lying around. The files that are not tracked are named in the note,
;; so nothing is lost silently.
;;
;; Registered in plan/package-tree.org; lands with TODO item 12.

(require racket/file
         racket/path
         racket/list
         racket/path
         racket/port
         racket/string
         racket/system
         "../machine/directories.rkt")

;; checkpoints-dir is where the checkpoints are kept: the commit is in the
;; tree's own history, and the record of it is here.
(define checkpoints-dir
  (build-path (state-dir) "checkpoints"))

;; tracked-files answers the files git tracks, as paths relative to the
;; tree's root. The files that are NOT tracked are the ones a blanket add
;; would sweep in, and they are named in the checkpoint's note.
(define (tracked-files root)
  (define output (run-git root "ls-files"))
  (filter (lambda (line) (not (string=? line "")))
          (string-split output "\n")))

;; untracked-files answers the files git does not track, the ones a
;; blanket add would sweep in. They are named in the note, so nothing is
;; lost silently.
(define (untracked-files root)
  (define output (run-git root "ls-files" "--others" "--exclude-standard"))
  (filter (lambda (line) (not (string=? line "")))
          (string-split output "\n")))

;; git is the program that holds the tree's history, and shell is the one
;; that redirects what git prints into a file — this Racket's system*
;; takes no port, so the child is run through the shell. Both are named
;; by their whole path, so the program never depends on the PATH.
(define git "/usr/bin/git")

;; shell is the program that redirects what git prints into a file, and
;; it is named by its whole path too.
(define shell "/bin/sh")

;; run-git runs a git command in the tree and answers what it printed.
;; A command that fails answers the empty text, and the caller says so
;; rather than guessing.
(define (run-git root . arguments)
  (define out-file (build-path (state-dir) "git-out"))
  (define status-file (build-path (state-dir) "git-status"))
  (ensure-dir (state-dir))
  (define quoted
    (string-join
     (for/list ([a (in-list arguments)])
       (string-append "'" (if (path? a) (path->string a) a) "'"))
     " "))
  (define root-text (if (path? root) (path->string root) root))
  (system* shell
           "-c"
           (string-append git " -C '" root-text "' " quoted
                          " > '" (path->string out-file) "' 2>/dev/null; echo -n $? > '"
                          (path->string status-file) "'"))
  (if (file-exists? out-file) (file->string out-file) ""))

;; git-ok? answers whether a git command in the tree succeeded. A command
;; that says nothing is not a failure: the STATUS says, not the output.
(define (git-ok? root . arguments)
  (apply run-git root arguments)
  (define status-file (build-path (state-dir) "git-status"))
  (and (file-exists? status-file)
       (string=? (string-trim (file->string status-file)) "0")))

;; tree-root answers the tree a file lives in: the top level git knows, or
;; the file's own directory when the tree is not a git one.
(define (tree-root file)
  ;; a directory is the tree it is in; a file is the tree of the
  ;; directory that holds it
  (define directory
    (simplify-path
     (path->complete-path
      (if (directory-exists? file) file (build-path file 'up)))))
  (define answer (string-trim (run-git directory "rev-parse" "--show-toplevel")))
  (if (string=? answer "") directory answer))

;; checkpoint makes a checkpoint of the tree and answers the name of it:
;; the commit it made. The files are added one by one, and the note names
;; the files that were not tracked.
(define (checkpoint root why)
  (if (string=? (string-trim why) "")
      #f
      (let* ([files (tracked-files root)]
             [loose (untracked-files root)]
             [note (format "the checkpoint before an agent acted: ~a~a"
                           why
                           (if (null? loose)
                               ""
                               (format "~nnot tracked, so not in this commit: ~a"
                                       (string-join loose " "))))])
        (for ([file (in-list files)])
          (run-git root "add" "--" file))
        (define note-file (build-path (state-dir) "git-note"))
        (call-with-output-file note-file
          (lambda (port) (display note port))
          #:exists 'truncate)
        (define made (run-git root "commit" "-F" note-file "--allow-empty"))
        (if (string=? made "")
            #f
            (let ([name (string-trim (run-git root "rev-parse" "--short" "HEAD"))])
              (remember-checkpoint name)
              name)))))

;; checkpoints-file is where the names of the checkpoints are kept, one
;; per line, newest last.
(define checkpoints-file
  (build-path checkpoints-dir "checkpoints"))

;; checkpoints answers the checkpoints that were made, newest last.
(define (checkpoints)
  (if (file-exists? checkpoints-file)
      (filter (lambda (line) (not (string=? line "")))
              (string-split (file->string checkpoints-file) "\n"))
      '()))

;; remember-checkpoint writes the name of a checkpoint down, so the list
;; of them survives the session.
(define (remember-checkpoint name)
  (ensure-dir checkpoints-dir)
  (call-with-output-file checkpoints-file
    (lambda (port)
      (for ([other (in-list (checkpoints))])
        (display other port)
        (newline port))
      (display name port)
      (newline port))
    #:exists 'truncate)
  name)

;; The checkpoint, for the rollback beside it.
(provide checkpoints-dir
         tree-root
         git-ok?
         checkpoints-file
         tracked-files
         untracked-files
         run-git
         checkpoint
         checkpoints
         remember-checkpoint)
