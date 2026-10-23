#lang racket/base
;; One job: the git check — the editor reads the shared Git layer through
;; the join seam, and the seam holds.
;;
;; The check makes a real repository in a temporary directory, asks the
;; hot path what Git says about a file in it, and checks the answers: the
;; branch, the counts, and the file's own state in the index and in the
;; working tree, which are two different states. Then it asks about a
;; file that is in no repository at all, and the answer must refuse it
;; by name instead of pretending the tree is clean. Last it checks that
;; the inspection changed nothing: the repository says the same before
;; and after.
;;
;; The hot path is the Rust side of the seam. It is found the way the
;; program finds it: the environment names it, or the build's own
;; directory holds it. The check runs from the gate directory, so the
;; package is reached by a relative path: a module path that holds a
;; space cannot be opened by an absolute one on this Racket.

(require racket/file
         racket/port
         racket/string
         racket/system
         "../editor/src/join/transport.rkt"
         "../editor/src/join/protocol.rkt"
         "../editor/src/machine/directories.rkt")

;; the-name is the name the check gives its own repository and its own
;; commits, so the check never depends on a git configuration on this
;; phone.
(define the-name "AIU editor gate")

;; the-mail is the mail the check's own commits carry, so the check never
;; depends on a git configuration on this phone.
(define the-mail "gate@localhost")

;; make-repository makes a real repository in a temporary directory, with
;; one file committed in it, and answers the directory and the file.
(define (make-repository)
  (define directory (make-temporary-directory "aiu-git-check-~a"))
  (define file (build-path directory "notes.txt"))
  (call-with-output-file file #:exists 'truncate
    (lambda (out) (display "the first line\n" out)))
  (parameterize ([current-directory directory])
    (git "init" "-b" "main")
    (git "add" "notes.txt")
    (git "-c" (format "user.name=~a" the-name)
         "-c" (format "user.email=~a" the-mail)
         "commit" "-m" "the first commit"))
  (values directory file))

;; git runs one git command in the current directory, and answers what it
;; said. A command that fails says so in the failure, and the check
;; stops there.
(define (git . args)
  (define out (open-output-string))
  (define err (open-output-string))
  (define code
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (apply system*/exit-code (git-bin) args)))
  (unless (and (integer? code) (zero? code))
    (error 'git-check
           (format "the git command ~a failed: ~a" (string-join args " ") (get-output-string err))))
  (get-output-string out))

;; ask asks the hot path one question, and answers the data of the
;; answer. The names and the values are the seam's shape: all strings.
(define (ask op file)
  (define answer
    (call-over-wire (hot-path-bin) '()
                    (hasheq 'op op 'args (hasheq 'file (path->string file)))))
  (response-data answer))

;; the-value answers one name of an answer, and the empty string when the
;; answer does not hold it.
(define (the-value data name)
  (define found (hash-ref data name ""))
  (if (string? found) found (format "~a" found)))

;; status-of answers what git says about the repository in one line, so
;; the check can compare the repository before and after.
(define (status-of directory)
  (parameterize ([current-directory directory])
    (string-trim (git "status" "--porcelain"))))

;; main runs the check and answers what is wrong, one line per fault. It
;; exits non-zero when a fault is found.
(define (main)
  (define faults '())
  (define-values (directory file) (make-repository))
  (define clean (ask "git" file))
  (unless (string=? (the-value clean 'git-branch) "main")
    (set! faults (cons (format "the branch is ~a, and it should be main"
                                (the-value clean 'git-branch)) faults)))
  (unless (string=? (the-value clean 'git-file-working) "clean")
    (set! faults (cons (format "a committed file is ~a in the working tree, and it should be clean"
                                (the-value clean 'git-file-working)) faults)))
  (unless (string=? (the-value clean 'git-unstaged) "0")
    (set! faults (cons (format "the repository holds ~a unstaged changes, and it should hold none"
                                (the-value clean 'git-unstaged)) faults)))
  ;; the file changes, and the facts must say so: the working tree and
  ;; the index are two states, and here they differ.
  (call-with-output-file file #:exists 'truncate
    (lambda (out) (display "the first line\nthe second line\n" out)))
  ;; the state of the repository right before the inspection that follows:
  ;; the inspection must leave the repository exactly as it found it.
  (define before (status-of directory))
  (define changed (ask "git" file))
  (unless (string=? (the-value changed 'git-file-working) "modified")
    (set! faults (cons (format "a changed file is ~a in the working tree, and it should be modified"
                                (the-value changed 'git-file-working)) faults)))
  (unless (string=? (the-value changed 'git-file-index) "unchanged")
    (set! faults (cons (format "the index says ~a of the file, and it should say unchanged"
                                (the-value changed 'git-file-index)) faults)))
  (unless (string=? (the-value changed 'git-unstaged) "1")
    (set! faults (cons (format "the repository holds ~a unstaged changes, and it should hold one"
                                (the-value changed 'git-unstaged)) faults)))
  ;; the diff of the changed file: the comparison is named, and the hunk
  ;; holds the line that changed.
  (define difference (ask "git-diff" file))
  (unless (string=? (the-value difference 'git-diff-comparison) "working tree against index")
    (set! faults (cons (format "the comparison is ~a, and it should be the working tree against the index"
                                (the-value difference 'git-diff-comparison)) faults)))
  (unless (string=? (the-value difference 'git-diff-hunks) "1")
    (set! faults (cons (format "the diff holds ~a hunks, and it should hold one"
                                (the-value difference 'git-diff-hunks)) faults)))
  ;; a file that is in no repository at all: the answer refuses it by
  ;; name, and it never says the tree is clean.
  (define outside (build-path (make-temporary-directory "aiu-git-outside-~a") "nothing.txt"))
  (define refused (ask "git" outside))
  (unless (string=? (the-value refused 'git-state) "unknown")
    (set! faults (cons (format "a file outside a repository is ~a, and it should be refused"
                                (the-value refused 'git-state)) faults)))
  (when (string=? (the-value refused 'git-file-working) "clean")
    (set! faults (cons "a file outside a repository was reported as clean" faults)))
  ;; the inspection changed nothing: the repository says the same.
  (unless (string=? before (status-of directory))
    (set! faults (cons "the inspection changed the repository" faults)))
  (if (null? faults)
      (begin
        (printf "OK git-check — the facts, the diff and the refusal hold, and the repository is untouched\n")
        (exit 0))
      (begin
        (for ([fault (in-list (reverse faults))])
          (printf "FAIL git-check — ~a\n" fault))
        (exit 1))))

(module+ main
  (main))
