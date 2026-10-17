#lang racket/base
;; One job: the one place HOME / XDG is read.
;; Lands with TODO item 1 (the floor). No other file reads HOME or XDG; if a
;; file needs a path, it asks here.

(require racket/file
         "../errors/raise.rkt")

;; home-dir reads HOME once per call and says so plainly when it is missing,
;; because a package that guesses a home directory is a package that writes
;; files where nobody can find them.
(define (home-dir)
  (define h (getenv "HOME"))
  (if (and (string? h) (> (string-length h) 0))
      h
      (raise-err 'directories "directories.rkt" "HOME is not set; refusing to guess")))

;; xdg-dir reads one XDG variable, falling back to the spec's default under
;; the home directory. The variable name is an argument so no other file has to
;; spell an environment name.
(define (xdg-dir name fallback)
  (define v (getenv name))
  (cond
    [(and (string? v) (> (string-length v) 0)) v]
    [else (build-path (home-dir) fallback)]))

;; notation-data-dir is where this package keeps what it caches: the XDG data
;; directory, then "notation".
(define (notation-data-dir)
  (build-path (xdg-dir "XDG_DATA_HOME" ".local/share") "notation"))

;; ensure-dir creates a directory and its parents, then returns the path.
;; Creating is a write, so it says what it is about to do first.
(define (ensure-dir path)
  (when (not (directory-exists? path))
    (make-directory* path))
  path)

;; notation-state-dir is where a run's own state lives: the XDG state
;; directory, then "notation".
(define (notation-state-dir)
  (ensure-dir (build-path (xdg-dir "XDG_STATE_HOME" ".local/state") "notation")))