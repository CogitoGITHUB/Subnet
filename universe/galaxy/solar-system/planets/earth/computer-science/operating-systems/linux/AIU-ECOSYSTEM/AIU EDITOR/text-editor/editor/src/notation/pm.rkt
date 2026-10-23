#lang racket/base
;; One job: the PM seam — the editor asks the package manager, and it
;; never installs anything by itself.
;;
;; pm's rule is the editor's rule: reading is free, changing the disk
;; needs the human's confirmation. The editor passes that confirmation
;; only when the human asked for the change.
;;
;; Registered in plan/package-tree.org; lands with TODO item 17.

(require racket/file
         racket/list
         racket/string
         "../machine/directories.rkt"
         "../machine/run.rkt")

;; pm-cli answers the pm program this editor asks: the one named by
;; AIU_PM_CLI, or the one found by walking up the tree. When there is
;; none, the answer is nothing, and the caller says so by name.
(define (pm-cli)
  (define named (getenv "AIU_PM_CLI"))
  (if (and named (not (string=? named "")))
      (path->complete-path named)
      (let loop ([at (simplify-path (current-directory))])
        (define up (simplify-path (build-path at "..")))
        (define found (build-path at "AIU-OS" "AIU-PM" "package-manager" "src" "entry" "cli.rkt"))
        (cond
          [(file-exists? found) found]
          [(string=? (path->string at) (path->string up)) #f]
          [else (loop up)]))))

;; pm-command answers the command that runs pm: the program named by
;; the path, with Racket in front of it when the program is a Racket
;; program.
(define (pm-command cli)
  (if (string-suffix? (path->string cli) ".rkt")
      (let ([racket (racket-bin)])
        (if racket
            (list (path->string racket) (path->string cli))
            (list (path->string cli))))
      (list (path->string cli))))

;; pm-verb runs one pm verb and answers what it did: the text pm
;; printed, the text it complained with, the code it left, and whether
;; it was good.
(define (pm-verb args)
  (define cli (pm-cli))
  (cond
    [(not cli)
     (hash 'ok #f 'code -1 'out ""
           'err "the editor does not know where pm is: set AIU_PM_CLI to the pm program")]
    [else
     (define words (append (pm-command cli) (list "--format" "json") args))
     (define result (run-program (string-join (map shell-quote words) " ") 60))
     (hash-set result 'ok (= (hash-ref result 'code -1) 0))]))

;; pm-apply asks pm to install a spec. It changes the disk, so it only
;; happens when the human's confirmation is there: the editor never
;; installs anything by itself.
(define (pm-apply spec confirmation)
  (if (not confirmation)
      (hash 'ok #f 'code -1 'out ""
            'err "the install was not made: it changes the disk, and the human's confirmation is needed")
      (pm-verb (list "apply" spec "--confirm"))))

;; pm-verify asks pm whether what is installed is really what it
;; claims. It reads, so it is free.
(define (pm-verify vault lockfile name)
  (pm-verb (list "verify" vault lockfile name)))

;; The pm seam, for the areas above it.
(provide pm-cli
         pm-command
         pm-verb
         pm-apply
         pm-verify)
