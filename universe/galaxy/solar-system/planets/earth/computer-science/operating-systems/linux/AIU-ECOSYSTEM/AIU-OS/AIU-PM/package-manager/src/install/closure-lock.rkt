#lang racket/base
;; closure-lock.rkt -- the one lock that spans a whole install closure
;; (G-02, D-038: "a lock over the whole closure rather than one
;; package").
;;
;; There is ONE lock mechanism in this tree and this module does not
;; add a second: it is git/vault-lock.rkt's call-with-vault-lock (a
;; process-local semaphore, a Racket file lock, and an owner record
;; beside them), attempted ONCE and never waited on. What this module
;; adds is the SCOPE and the refusal's own wording, because using the
;; vault lock directly for an install was wrong in two ways:
;;
;;   1. The scope was the wrong unit. call-with-vault-lock puts its lock
;;      at the SIBLING named "vault.lock" of the root it is handed, so
;;      handing it the state dir put one lock file in the state dir's
;;      PARENT: every state dir under one parent shared it, so two
;;      unrelated install roots refused each other, and the file that
;;      ruled an install was not inside the install root at all. A
;;      closure is per install root, so closure-lock-file below hands
;;      the mechanism a marker one level BELOW the install root and the
;;      lock file lands inside the root and only there.
;;   2. The refusal said "vault busy" with a "vault" field. For an
;;      install that is a name that lies, and a refusal whose wording
;;      does not match the thing refused teaches the reader to guess.
;;      So the busy signal is translated here, once, at this boundary,
;;      into an install refusal that still names the holder exactly as
;;      the vault lock renders it.
;;
;; WHAT IS INSIDE one closure, and why it is all of it (G-02): the
;; empty vault init, the specs scan and its per-package vault
;; preflight, the lockfile comparison, the per-package prefix dirs, the
;; resolve and derive, every package's journalled steps in resolve
;; order, and the manifest upsert. Those are one closure because two
;; applies that share them are two writes into one store, one prefix
;; and one journal, and the second must be refused BEFORE it has
;; changed anything rather than halfway through a package. The lock is
;; taken outside all of them, so the refusal lands on a machine this
;; run has not touched.
;;
;; WHAT IS DELIBERATELY NOT inside, and why:
;;   - journal queries and status reads. They never write, and a reader
;;     that had to take the writer's lock would be useless exactly when
;;     it is most wanted: while an install runs.
;;   - a dry run. pm-apply-dry and pm-apply's dry branch render plans
;;     and change nothing (D-040), so there is nothing to interleave
;;     with and nothing to protect.
;;   - the vault's own git writes. Those are git/'s business under its
;;     own lock, keyed on the vault root. pm apply only preflights that
;;     the pin already resolves there, and the plan's own fetch action
;;     is filtered out because the vault holds the pin (apply.rkt
;;     apply-one).
;;   - another install root. Two install roots side by side are two
;;     closures and neither refuses the other, which is the whole point
;;     of closure-lock-file.
;;
;; REFUSAL, NOT A HANG (D-041). The mechanism is try-only, so the
;; attempt either wins or fails at once and nothing here ever waits on
;; another apply. The attempt is narrated by the caller's wait-for
;; BEFORE it is made, so a refusal is never silent.

(require racket/contract/base
         racket/file
         racket/path
         racket/string
         "../errors/error-type.rkt"
         "../git/vault-lock.rkt"
         "../narration/narration.rkt")

(provide
 (contract-out
  ;; install-root -> path, where this root's closure lock file lands.
  ;; One line under the root, never beside it.
  [closure-lock-file (-> path-string? path?)]
  ;; install-root holder-id holder-note thunk -> any. Try once over the
  ;; whole closure; when the root is already held this refuses at once,
  ;; naming the holder, and never waits. [#:on-stale-holder] is the
  ;; mechanism's own crash callback, passed straight through: a holder
  ;; that died leaves a stale owner record, and the next acquisition
  ;; succeeds while reporting who died.
  [call-with-closure-lock
   (->* (path-string? string? string? (-> any/c))
        (#:on-stale-holder (or/c (-> holder? any/c) #f))
        any/c)]))

;; The words the refusal uses for the scope it refused. One string, one
;; place, so the refusal and this module's header cannot drift apart.
(define closure-scope-text
  (string-append
   "the whole apply: vault init, specs scan, prefix dirs, resolve, "
   "every package's journalled steps, and the manifest write"))

;; install-root -> path, the marker root handed to the mechanism.
;;
;; call-with-vault-lock places its lock at (sibling "vault.lock") of the
;; root it is given, so a root one level below the install root puts the
;; lock file AND the owner record inside the install root. The marker
;; itself is never created and never read: it exists only to place the
;; two files, and naming it after the thing it protects keeps the
;; reader's question ("what is this file for?") answerable from the
;; path alone.
(define (closure-lock-file install-root)
  (build-path (string->path install-root) "install-closure"))

;; path-string -> void, the install root must exist before the owner
;; record can be written inside it. D-041: it says so first, because a
;; directory creation is a filesystem wait like any other.
(define (ensure-install-root install-root)
  (wait-for 'closure-lock "install-root"
            "the lock file and the holder record live inside the install root, so it must exist first"
            #:how (format "create ~a" install-root)
            (lambda ()
              (make-directory* (string->path install-root))
              (void))))

;; exn -> boolean, is this the lock mechanism's busy refusal?
;;
;; Matched on the kind AND on the refusal's own text, because the `who`
;; symbol never reaches the exception struct -- it is only rendered into
;; the message -- and the text is what the mechanism promised to say
;; (vault-lock.rkt raise-busy). That text is the coupling, so it is
;; written down here: change the wording THERE and this must change
;; with it, or a busy closure silently stops being translated and the
;; install refusal a reader was told to expect never arrives.
;; Any other kind 'config error raised under the thunk passes straight
;; through untouched: install must not swallow a refusal it did not
;; cause.
(define (lock-busy? e)
  (and (config-error? e)
       (regexp-match? #rx"vault busy" (exn-message e))))

;; install-root string exn -> never returns. The install refusal for a
;; closure that is already held.
;;
;; The holder field is COPIED verbatim out of the mechanism's refusal,
;; so the holder id, its note and its start time read exactly as they do
;; for a vault write; only the noun changes. The hint is the next step
;; (refusal-wording.org): this one changed nothing, so the answer is to
;; wait for the named apply and run again, never to force the lock.
(define (raise-closure-busy install-root id e)
  (define holder-cell (assoc "holder" (exn-fail:pm-fields e)))
  (raise-pm-error
   'config
   'call-with-closure-lock
   "install closure busy"
   #:fields `(("closure" . ,install-root)
              ("waiting for" . ,id)
              ("holder" . ,(if holder-cell
                               (cdr holder-cell)
                               "unknown (no owner record; live foreign holder?)"))
              ("scope" . ,closure-scope-text))
   #:hint (string-append
           "let the named apply finish, then run this one; "
           "nothing in this one has changed")))

;; install-root id note thunk [#:on-stale-holder] -> any
;; The closure held for the whole of THUNK. Nothing here waits: the
;; mechanism is try-only, so a busy closure is a refusal at once.
(define (call-with-closure-lock install-root id note thunk
                                #:on-stale-holder [on-stale-holder #f])
  (ensure-install-root install-root)
  (with-handlers ([exn:fail:pm?
                   (lambda (e)
                     (if (lock-busy? e)
                         (raise-closure-busy install-root id e)
                         (raise e)))])
    (call-with-vault-lock (closure-lock-file install-root)
                          id note thunk
                          #:on-stale-holder on-stale-holder)))
