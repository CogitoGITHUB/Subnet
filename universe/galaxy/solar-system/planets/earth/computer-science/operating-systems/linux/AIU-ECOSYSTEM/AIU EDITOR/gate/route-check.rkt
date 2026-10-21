#lang racket/base
;; One job: the route check — the reserved prefix is bound by no layer, and
;; every route names a command the command table really holds. Registered in
;; plan/package-tree.org; lands with TODO item 4.
;;
;; The contract asks for it in one line: "Routes are additive; a route that
;; collides with the reserved prefix is refused by a gate." This is that
;; gate. It reads the routing tables and the command table, and it fails
;; when a route would take a key that belongs to the multiplexer or when a
;; route names a command that does not exist.
;;
;; The check runs from the gate directory, so the tables are reached by a
;; relative path: a module path that holds a space cannot be opened by an
;; absolute one on this Racket.

(require racket/list
         racket/set
         "../editor/src/routes/routes.rkt"
         "../editor/src/commands/commands.rkt"
         "../editor/src/dashboard/explorer.rkt")

;; known-commands answers the names the command table holds, as a set, so
;; the check can ask about a command name in one step.
(define known-commands
  ;; The table is read as it stands: a command that was added when its
  ;; module was loaded is a command the editor really holds.
  (for/set ([name (in-list (hash-keys commands))]) name))

;; unknown-command-routes answers the routes that name a command the
;; command table does not hold. Each one is a route that would run
;; nothing.
(define (unknown-command-routes)
  (for/list ([route (in-list (route-commands))]
             #:unless (set-member? known-commands (third route)))
    route))

;; main checks the routes and answers what is wrong, one line per fault.
;; It exits non-zero when a fault is found.
(define (main)
  (define collisions (reserved-prefix-collisions))
  (define unknown (unknown-command-routes))
  (define route-count (length (route-commands)))
  (if (and (null? collisions) (null? unknown))
      (begin
        (printf "OK route-check — ~a routes checked, the reserved prefix is bound by no layer, every route names a command that exists\n"
                route-count)
        (exit 0))
      (begin
        (for-each (lambda (collision)
                    (printf "ROUTE — the key ~a in the layer ~a is the reserved prefix; the multiplexer keeps it and no layer may bind it\n"
                            (second collision) (first collision)))
                  collisions)
        (for-each (lambda (route)
                    (printf "ROUTE — the route ~a ~a names the command ~a, and the command table does not hold it\n"
                            (first route) (second route) (third route)))
                  unknown)
        (printf "ROUTE — ~a faults in ~a routes\n"
                (+ (length collisions) (length unknown))
                route-count)
        (exit 1))))

;; The check, for the dispatcher above.
(module+ main
  (main))
