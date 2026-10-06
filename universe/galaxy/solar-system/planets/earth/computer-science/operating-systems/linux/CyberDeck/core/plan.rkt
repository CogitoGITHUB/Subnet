#lang racket/base
;; plan.rkt -- immutable action structs plus plan text. Pure, no I/O.
;; Full spec-to-plan derivation waits for the resolve phase; this module
;; holds the data model, the plan container and the stable renderer that
;; dry-run prints and golden tests compare (A-3).

(require racket/contract/base
         racket/string
         "errors.rkt")

(provide
 (struct-out fetch-action)
 (struct-out verify-action)
 (struct-out extract-action)
 (struct-out run-step-action)
 (struct-out install-file-action)
 (struct-out write-file-action)
 (struct-out symlink-action)
 (struct-out remove-path-action)
 (struct-out plan)
 (contract-out
  ;; any -> boolean, one of the eight action kinds below
  [action? (-> any/c boolean?)]
  ;; plan -> string, one line per action in order, stable for goldens
  [plan->text (-> plan? string?)]
  ;; (listof action) -> plan
  [list->plan (-> (listof action?) plan?)]))

;; ---------------------------------------------------------------------------
;; Guard helper

;; string any -> void, fields must be strings (backend converts at edge)
(define (check-string-fields who pairs)
  (for ([p (in-list pairs)])
    (unless (string? (cdr p))
      (raise-pm-error 'internal who "action field must be a string"
                      #:fields `(("field" . ,(car p))
                                 ("value" . ,(cdr p)))))))

;; ---------------------------------------------------------------------------
;; Actions (A-3: data first, effects at the edge; paths stay strings here
;; so plans print and diff stably; the local backend converts at its edge)

(struct fetch-action (url commit dest)
  #:transparent
  #:guard (lambda (url commit dest _n)
            (check-string-fields 'fetch-action
                                 `(("url" . ,url) ("commit" . ,commit)
                                   ("dest" . ,dest)))
            (values url commit dest)))
;; url commit dest : string?  what to fetch, exact pin, where to stage it

(struct verify-action (path expected-hash algorithm)
  #:transparent
  #:guard (lambda (path expected-hash algorithm _n)
            (check-string-fields 'verify-action
                                 `(("path" . ,path)
                                   ("expected-hash" . ,expected-hash)
                                   ("algorithm" . ,algorithm)))
            (values path expected-hash algorithm)))
;; path expected-hash algorithm : string?  integrity check before use

(struct extract-action (src dest)
  #:transparent
  #:guard (lambda (src dest _n)
            (check-string-fields 'extract-action
                                 `(("src" . ,src) ("dest" . ,dest)))
            (values src dest)))
;; src dest : string?  export a tree from the vault mirror at its pin

(struct run-step-action (name argv cwd)
  #:transparent
  #:guard (lambda (name argv cwd _n)
            (check-string-fields 'run-step-action
                                 `(("name" . ,name) ("cwd" . ,cwd)))
            (unless (and (list? argv) (andmap string? argv)
                         (pair? argv))
              (raise-pm-error 'internal 'run-step-action
                              "argv must be a nonempty string list"
                              #:fields `(("value" . ,argv))))
            (values name argv cwd)))
;; name cwd : string?  step label and working directory for E-8 output
;; argv : (nonempty-listof string?)  exact command, never a shell string

(struct install-file-action (src dest mode)
  #:transparent
  #:guard (lambda (src dest mode _n)
            (check-string-fields 'install-file-action
                                 `(("src" . ,src) ("dest" . ,dest)))
            (unless (and (exact-integer? mode) (<= 0 mode #o777))
              (raise-pm-error 'internal 'install-file-action
                              "mode must be an octal permission"
                              #:fields `(("value" . ,mode))))
            (values src dest mode)))
;; src dest : string?  staged file to its versioned home
;; mode : (integer-in 0 511)  permission bits, preserved from export

(struct write-file-action (path content)
  #:transparent
  #:guard (lambda (path content _n)
            (check-string-fields 'write-file-action
                                 `(("path" . ,path)
                                   ("content" . ,content)))
            (values path content)))
;; path content : string?  generated files (autoloads, stamps, manifests)

(struct symlink-action (target link)
  #:transparent
  #:guard (lambda (target link _n)
            (check-string-fields 'symlink-action
                                 `(("target" . ,target) ("link" . ,link)))
            (values target link)))
;; target link : string?  the `current` link flip is one of these

(struct remove-path-action (path)
  #:transparent
  #:guard (lambda (path _n)
            (check-string-fields 'remove-path-action `(("path" . ,path)))
            (values path)))
;; path : string?  cleanup of staging on failure, explicit and logged

;; any -> boolean, one of the eight action kinds
(define (action? v)
  (or (fetch-action? v) (verify-action? v) (extract-action? v)
      (run-step-action? v) (install-file-action? v)
      (write-file-action? v) (symlink-action? v)
      (remove-path-action? v)))

(struct plan (actions)
  #:transparent
  #:guard (lambda (actions _n)
            (unless (and (list? actions) (andmap action? actions))
              (raise-pm-error 'internal 'plan
                              "plan holds action structs only"
                              #:fields `(("value" . ,actions))))
            (values actions)))
;; actions : (listof action?)  ordered, interpreted top to bottom

;; (listof action) -> plan
(define (list->plan actions)
  (plan actions))

;; ---------------------------------------------------------------------------
;; Rendering (stable text for dry-run output and golden files)

;; action -> string, one line
(define (action->line a)
  (cond [(fetch-action? a)
         (format "fetch ~a @ ~a -> ~a"
                 (fetch-action-url a)
                 (fetch-action-commit a)
                 (fetch-action-dest a))]
        [(verify-action? a)
         (format "verify ~a ~a:~a"
                 (verify-action-path a)
                 (verify-action-algorithm a)
                 (verify-action-expected-hash a))]
        [(extract-action? a)
         (format "extract ~a -> ~a"
                 (extract-action-src a) (extract-action-dest a))]
        [(run-step-action? a)
         (format "run-step ~a [~a] in ~a"
                 (run-step-action-name a)
                 (string-join (run-step-action-argv a) " ")
                 (run-step-action-cwd a))]
        [(install-file-action? a)
         (format "install-file ~a -> ~a mode ~a"
                 (install-file-action-src a)
                 (install-file-action-dest a)
                 (number->string (install-file-action-mode a) 8))]
        [(write-file-action? a)
         (format "write-file ~a (~a bytes)"
                 (write-file-action-path a)
                 (string-length (write-file-action-content a)))]
        [(symlink-action? a)
         (format "symlink ~a -> ~a"
                 (symlink-action-link a) (symlink-action-target a))]
        [(remove-path-action? a)
         (format "remove-path ~a" (remove-path-action-path a))]
        [else (raise-pm-error 'internal 'action->line "not an action"
                              #:fields `(("value" . ,a)))]))

;; plan -> string, one line per action in order, stable for goldens
(define (plan->text p)
  (string-join (map action->line (plan-actions p)) "\n"))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           "errors.rkt")

  ;; Every action builds and predicates sort them.
  (define fetch-1
    (fetch-action "https://example.org/r.git" (make-string 40 #\a) "/tmp/s"))
  (check-true (action? fetch-1))
  (check-false (action? "fetch"))
  (check-false (action? 42))

  ;; Guards reject with kind 'internal (programmer-side construction).
  (define (internal-kind thunk)
    (with-handlers ([exn:fail:pm? exn:fail:pm-kind])
      (thunk)
      #f))
  (check-eq? (internal-kind (lambda () (fetch-action 42 "c" "d")))
             'internal)
  (check-eq? (internal-kind
              (lambda () (run-step-action "n" '() "d")))
             'internal)
  (check-eq? (internal-kind
              (lambda () (run-step-action "n" "not-a-list" "d")))
             'internal)
  (check-eq? (internal-kind
              (lambda () (install-file-action "s" "d" #o1000)))
             'internal)
  (check-eq? (internal-kind (lambda () (plan '(1 2 3)))) 'internal)
  (check-pred internal-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (plan '(oops))))

  ;; Golden: a hand-built plan renders to stable text.
  (define golden-plan
    (list->plan
     (list fetch-1
           (verify-action "/tmp/s" (make-string 64 #\b) "sha256")
           (extract-action "/tmp/s" "/tmp/stage")
           (run-step-action "compile" '("make" "-j4") "/tmp/stage")
           (install-file-action "/tmp/stage/a.el" "/pkg/a.el" #o644)
           (write-file-action "/pkg/pin" "9edb3f66")
           (symlink-action "/pkg/1.0" "/pkg/current")
           (remove-path-action "/tmp/stage"))))
  (check-equal?
   (plan->text golden-plan)
   (string-join
    (list (string-append "fetch https://example.org/r.git @ "
                         (make-string 40 #\a) " -> /tmp/s")
          (string-append "verify /tmp/s sha256:" (make-string 64 #\b))
          "extract /tmp/s -> /tmp/stage"
          "run-step compile [make -j4] in /tmp/stage"
          "install-file /tmp/stage/a.el -> /pkg/a.el mode 644"
          "write-file /pkg/pin (8 bytes)"
          "symlink /pkg/current -> /pkg/1.0"
          "remove-path /tmp/stage")
    "\n"))

  ;; Empty plan renders empty.
  (check-equal? (plan->text (list->plan '())) ""))
