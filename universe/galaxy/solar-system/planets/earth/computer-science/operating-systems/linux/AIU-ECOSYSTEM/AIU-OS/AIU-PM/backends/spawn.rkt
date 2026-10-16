#lang racket/base
;; spawn.rkt -- create and start the child: the prelude that validates
;; #:cwd BEFORE anything exists, the wrapper script, the fifo, and the
;; wrapped process* call. It must not wait, collect output, or kill.
;;
;; This is the piece that decides whether a child ever runs at all. Every
;; refusal here happens BEFORE a temp dir, a fifo or a process exists, so
;; a bad request is reported instead of becoming a parent that waits for
;; a child that was never going to speak.

(require racket/file
         racket/string
         racket/system
         "../core/errors.rkt"
         "status-fifo.rkt")

(provide
 ;; string, the wrapper all children run under
 status-script
 ;; (listof (cons string string)) -> (listof string), NAME=value assignments
 env-assignments
 ;; path-string string (listof string) -> string, argv text with paths rendered
 command-text
 ;; -> (values setsid pkill env sh exe-string temp-dir status-path)
 spawn-prelude
 ;; -> (list any), spawn or raise kind 'config synchronously
 spawn-wrapped)

;; ---------------------------------------------------------------------------
;; Environment (S-6): fixed allowlist, everything else dropped.

;; Fixed variable names passed to every child.
(define fixed-env-names
  '("PATH" "HOME" "LANG" "SSH_AUTH_SOCK"
    "http_proxy" "https_proxy" "HTTP_PROXY" "HTTPS_PROXY"
    "no_proxy" "NO_PROXY"))

;; (listof (cons string string)) -> void, bad names are our bug (internal)
(define (check-env-names extras)
  (for ([p (in-list extras)])
    (unless (regexp-match? #rx"^[A-Za-z_][A-Za-z0-9_]*$" (car p))
      (raise-pm-error 'internal 'run-command "invalid environment variable name"
                      #:fields `(("name" . ,(car p)))))))

;; (listof (cons string string)) -> (listof string), NAME=value assignments
(define (env-assignments extras)
  (define table (make-hash))
  (for ([n (in-list fixed-env-names)])
    (define v (getenv n))
    (when v (hash-set! table n v)))
  (for ([p (in-list extras)])
    (hash-set! table (car p) (cdr p)))
  (hash-map table (lambda (n v) (string-append n "=" v))))

;; ---------------------------------------------------------------------------
;; Spawning with whole-tree kill on cancel.
;; Racket process groups are unavailable under proot
;; (subprocess-group-enabled -> #f, probed 2026-10-06), so children launch
;; via setsid (own process group) and die via pkill -g on cancel.
;; make-environment-variables also segfaults under this proot (probed
;; 2026-10-06), so the allowlist is enforced with env -i instead. Values
;; passed here are visible in ps output; never pass secrets via #:env.
;; The wrapper opens the status fifo FIRST (as its first act), traps
;; TERM/INT into a KILLED line, runs the command, and always ends with an
;; EXIT line carrying the command's own code. Spawn failure raises
;; synchronously with the cause attached.

;; -> path, helper binary or kind 'config when missing
(define (find-helper name)
  (or (find-executable-path name)
      (raise-pm-error 'config 'run-command "helper executable missing"
                      #:fields `(("helper" . ,name)))))

;; string, the wrapper all children run under. Argv carries the fifo path,
;; the executable and its arguments, so no shell quoting is ever needed.
;; The single write end is opened first and closed last: a reader can
;; neither strand in open (a writer is guaranteed) nor see early EOF (the
;; writer outlives every read). Racket fifo reads with zero writers return
;; EOF at once, so this ordering is load-bearing, not incidental.
(define status-script
  (string-append
   "fifo=\"$1\"; shift; exe=\"$1\"; shift; "
   "exec 3>\"$fifo\" || exit 99; "
   "trap 'echo \"KILLED:$?\" >&3' TERM INT; "
   "\"$exe\" \"$@\"; st=$?; echo \"EXIT:$st\" >&3"))

;; path-string string -> string, argv text with paths rendered
(define (command-text exe argv)
  (string-join
   (map (lambda (a) (if (path? a) (path->string a) a))
        (cons (if (path? exe) (path->string exe) exe) argv))
   " "))

;; path-string (listof string) string string pm-kind string
;; (listof (cons string string)) -> (values setsid pkill env sh exe-string
;; temp-dir status-path)
(define (spawn-prelude exe argv cwd kind operation extras)
  (check-env-names extras)
  (define setsid-exe (find-helper "setsid"))
  (define pkill-exe (find-helper "pkill"))
  (define env-exe (find-helper "env"))
  (define sh-exe (find-helper "sh"))
  (unless (file-exists? exe)
    (raise-pm-error 'config 'run-command "executable not found"
                    #:fields `(("exe" . ,exe))))
  ;; A cwd that is not an existing directory is refused HERE, before the
  ;; temp dir and the fifo are created and before anything is spawned.
  ;;
  ;; It used to reach process*, which chdirs the CHILD. The child died in
  ;; chdir before the wrapper's first act, so the wrapper never ran
  ;; `exec 3>"$fifo"` and never became a writer. The reader -- the only
  ;; thing that ever wakes wait-command -- then blocked inside open() on
  ;; the fifo's read end, for ever, silently: opening a fifo read end
  ;; waits for a writer that is not coming, and that is a BLOCK, not a
  ;; raise, so no handler could ever have caught it. process* hands back a
  ;; valid pid for that child, so the claim that a spawn failure raises
  ;; synchronously was false in this case.
  (unless (directory-exists? cwd)
    (raise-pm-error 'config 'run-command "cwd is not an existing directory"
                    #:fields `(("cwd" . ,(if (path? cwd)
                                            (path->string cwd)
                                            cwd))
                               ("operation" . ,operation))
                    #:hint (string-append
                            "the child is chdir'd there before it runs, so "
                            "create the directory first, or pass one that "
                            "already exists")))
  (define exe-string (if (path? exe) (path->string exe) exe))
  ;; Atomic exclusive create (mkdtemp): uniqueness never comes from a clock.
  (define temp-dir (make-temporary-directory "pm-run~a"))
  (define status-path (build-path temp-dir "status.fifo"))
  (make-status-fifo! (find-helper "mkfifo")
                     (path->string status-path)
                     operation)
  (values setsid-exe pkill-exe env-exe sh-exe exe-string temp-dir status-path))

;; path setsid env sh exe-string (listof string) (listof pairs) string
;; string -> (list any), spawn or raise kind 'config synchronously
(define (spawn-wrapped status-path setsid-exe env-exe sh-exe exe-string argv
                       extras cwd operation)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (raise-pm-error 'config 'run-command "spawn failed"
                                     #:fields `(("operation" . ,operation)
                                                ("command" . ,(command-text
                                                               exe-string argv)))
                                     #:cause e))])
    (parameterize ([current-directory cwd])
      (apply process* (path->string setsid-exe)
             (append (list (path->string env-exe) "-i")
                     (env-assignments extras)
                     (list (path->string sh-exe) "-c" status-script "sh"
                           (path->string status-path)
                           exe-string)
                     (map (lambda (a) (if (path? a) (path->string a) a))
                          argv))))))
