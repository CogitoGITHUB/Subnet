#lang racket/base
;; One job: the security gate's probe — every security rule is called on a
;; value that must be refused and on a value that must pass, and the answers
;; are checked against what the rule says it refuses.
;; Registered in plan/package-tree.org (gate/security-probe.rkt).
;;
;; Who calls it: gate/security-gate-lint.nu, the gate stage "security-gate".
;; It is a file and not an expression inside the stage because a program that
;; cannot be read is a program that cannot be checked, and the stage would
;; otherwise carry the whole check inside one string.
;;
;; The security area is opened with dynamic-require and an absolute path,
;; because the project directory holds a space and racket splits a path that
;; holds one when it is given as a plain argument. The paths are given on the
;; command line for the same reason: nothing here may assume where it runs.
;;
;; The probe also names, for every rule, the files that call it. A rule that
;; nobody calls refuses nothing today, and the stage says so out loud instead
;; of letting the reader believe the rule is already at work.

(require racket/file
         racket/list
         racket/port
         racket/string)

;; the-rules reads the security area and answers its rule list, its accessors
;; and the words each rule refuses, so every rule may be called the same way
;; and may be printed with the reason it exists.
(define (the-rules security-path)
  (define mod (string->path security-path))
  (list (dynamic-require mod 'security-rules)
        (dynamic-require mod 'security-rule-id)
        (dynamic-require mod 'security-rule-predicate)
        (dynamic-require mod 'security-rule-refuses)))

;; the-probes holds, for every rule id, the value that must be refused and the
;; value that must pass. A rule that answers the same way for both refuses
;; nothing, and this table is what says so.
(define the-probes
  (list
   (list 'target-names-no-file (list "") (list "out.txt"))
   (list 'target-is-a-directory (list "notes/") (list "out.txt"))
   (list 'path-escapes-root (list "../out.txt") (list "notes/out.txt"))
   (list 'absolute-target (list "/etc/out.txt") (list "out.txt"))
   (list 'target-is-the-document (list "doc.aiu" "doc.aiu") (list "out.aiu" "doc.aiu"))
   (list 'unwritable-place (list 'heading) (list 'file))
   (list 'opaque-body-reached (list 'chunk '(tags language)) (list 'tags '(tags language)))))

;; rkt-files-under lists every Racket file under a directory. The tree is
;; walked by hand because this racket has no glob of its own, and a gate that
;; cannot look at the tree cannot say who calls a rule.
(define (rkt-files-under dir)
  (define root (path->complete-path dir))
  (let walk ([d root] [out '()])
    (define entries
      (with-handlers ([exn:fail? (lambda (_) '())])
        (directory-list d)))
    (for/fold ([acc out]) ([e (in-list entries)])
      (define p (build-path d e))
      (cond
        [(directory-exists? p) (walk p acc)]
        [(string-suffix? (path->string e) ".rkt") (cons p acc)]
        [else acc]))))

;; files-calling answers, for one rule id, the Racket files under the package
;; that name it. The id is looked for as a whole word, because a rule named in
;; a longer word is not a call to that rule. The security area's own files are
;; left out, because a rule that names itself in its own vocabulary is not a
;; caller of that rule.
(define (files-calling package-src security-dir id)
  (define pattern (regexp (format "(?<![\\w-])~a(?![\\w-])" (regexp-quote (symbol->string id)))))
  (define prefix (if (and security-dir (not (string=? security-dir "")))
                     (if (string-suffix? security-dir "/") security-dir (string-append security-dir "/"))
                     ""))
  (for/list ([f (in-list (rkt-files-under package-src))]
             #:unless (and (not (string=? prefix "")) (string-prefix? (path->string f) prefix))
             #:when (regexp-match? pattern (file->string f)))
    f))

;; probe-one calls one rule on the value that must be refused and on the value
;; that must pass, and answers whether the rule behaved as it says.
(define (probe-one rule id predicate)
  (define found (findf (lambda (p) (eq? (car p) id)) the-probes))
  (cond
    [(not found) 'no-probe]
    [else
     (define refused (apply predicate (cadr found)))
     (define passed (apply predicate (caddr found)))
     (if (and refused (not passed)) 'ok 'wrong)]))

;; main runs every probe, prints one line per rule and one line per rule about
;; its callers, and then the count. It exits with 1 when a rule answered
;; wrongly, because a gate that says OK while a rule is broken is a gate that
;; lies.
(define (main)
  (define args (vector->list (current-command-line-arguments)))
  (cond
    [(< (length args) 2)
     (displayln "SECURITY-GATE: the security area path and the package path are needed")
     (exit 2)]
    [else
     (define parts (the-rules (car args)))
     (define package-src (cadr args))
     (define rules (car parts))
     (define rule-id (cadr parts))
     (define rule-predicate (caddr parts))
     (define rule-refuses (cadddr parts))
     (define wrong 0)
     (for ([r (in-list rules)])
       (define id (rule-id r))
       (define verdict (probe-one r id (rule-predicate r)))
       (cond
         [(eq? verdict 'ok)
          (printf "SECURITY-RULE ~a — ~a — probe ok\n" id (rule-refuses r))]
         [(eq? verdict 'no-probe)
          (printf "SECURITY-RULE ~a — ~a — no probe is written for it\n" id (rule-refuses r))
          (set! wrong (add1 wrong))]
         [else
          (printf "SECURITY-RULE ~a — ~a — probe WRONG: the value that must be refused and the value that must pass were answered the same\n"
                  id (rule-refuses r))
          (set! wrong (add1 wrong))]))
     (for ([r (in-list rules)])
       (define id (rule-id r))
       (define callers (files-calling package-src (if (< (length args) 3) "" (caddr args)) id))
       (if (null? callers)
           (printf "CALLER ~a — no file calls it yet\n" id)
           (for ([c (in-list callers)])
             (printf "CALLER ~a — ~a\n" id (path->string c)))))
     (define total (length rules))
     (printf "SECURITY-GATE: ~a rules, ~a probed ok, ~a wrong\n" total (- total wrong) wrong)
     (if (zero? wrong) (exit 0) (exit 1))]))

(module+ main
  (main))
