#lang racket/base
;; store.rkt -- own the on-disk shape: versioned dirs, the .pm-incomplete
;; marker, and the current link (ENGINE.org backends/store.rkt).
;;
;; Every path derives from the state root the caller hands over (which
;; the caller derives from the scope seam, E-00/D-029): no HOME, no XDG
;; and no find-system-path anywhere in this module. The folder name
;; carries the install identity (D-023): name/slot/version-hash12, the
;; same shape as package-plan-store-dir in core/plan.rkt.
;;
;; Marker discipline: the marker is created BEFORE the producer runs, so
;; anything written into the folder is covered; a failing producer keeps
;; the marker (it propagates through), a succeeding run clears it only
;; after every step succeeds (that clearing is the caller's job, checked
;; by check-marker-cleared). An existing dir that still carries a marker
;; is a dead run and refuses with kind 'config. The current link swaps
;; atomically (temporary link plus rename, never delete-then-link).

(require racket/contract/base
         racket/file
         "../errors/error-type.rkt"
         "../narration/narration.rkt")

(provide
 (contract-out
  ;; string string string string string (-> void) -> path, versioned dir
  ;; holding .pm-incomplete; producer fills the tree, marker stays
  [ensure-store-dir
   (-> string? string? string? string? string? (-> void?) path?)]
  ;; path -> boolean, marker still present
  [store-marker-present? (-> path-string? boolean?)]
  ;; path -> void, remove the marker after every step succeeds
  [clear-store-marker (-> path-string? void?)]
  ;; path -> void, kind 'install when the marker is still present
  [check-marker-cleared (-> path-string? void?)]
  ;; path-string -> path, ensure the dir holds .pm-incomplete
  [mark-store-dir (-> path-string? path?)]
  ;; path-string path-string -> path, atomic link flip, any target
  [swap-link! (-> path-string? path-string? path?)]
  ;; string string string path -> path, atomic current-link flip
  [set-store-current
   (-> string? string? string? path-string? path?)]))

;; string -> string, the incomplete marker leaf name
(define marker-leaf ".pm-incomplete")

;; path -> path, marker file inside a versioned dir
(define (marker-path dir)
  (build-path dir marker-leaf))

;; string string string string -> string, identity path below the store
(define (versioned-rel name slot version hash12)
  (string-append name "/" slot "/" version "-" hash12))

;; string string string string string (-> void) -> path, versioned dir
;; with the marker already in it; the producer runs after, so a raise
;; anywhere leaves the marker behind for the next run to see
(define (ensure-store-dir state-root name slot version hash12 producer)
  (define dir (build-path state-root "store"
                          (versioned-rel name slot version hash12)))
  ;; D-036: the store dir is where bytes land, so the whole thing is one
  ;; narrated operation: a fresh dir, a marker that names this run, and
  ;; the producer that fills it.
  (with-op 'store
           (string-append name "/" version)
           "a package version is being materialised in the store"
           #:how (path->string dir)
           #:inputs (list name version hash12)
           (lambda ()
             (when (and (directory-exists? dir)
                        (store-marker-present? dir))
               (skip 'store (path->string dir)
                     "a stale marker from a dead run is in this dir")
               (raise-pm-error 'config 'ensure-store-dir "dead run blocks the dir"
                               #:fields `(("dir" . ,(path->string dir)))
                               #:hint "clear the stale versioned dir by hand"))
             (make-directory* dir)
             (call-with-output-file (marker-path dir)
               (lambda (out) (void))
               #:exists 'truncate/replace)
             (step 'store "marker"
                   "the marker names this run so a dead one is detectable")
             (producer)
             dir)))

;; path -> boolean, marker still present
(define (store-marker-present? dir)
  (file-exists? (marker-path dir)))

;; path -> void, remove the marker after every step succeeds
(define (clear-store-marker dir)
  (define m (marker-path dir))
  (when (file-exists? m)
    (delete-file m)))

;; path -> void, kind 'install when the marker is still present: the
;; caller claimed success but the proof is missing, so fail closed
(define (check-marker-cleared dir)
  (when (store-marker-present? dir)
    (raise-pm-error 'install 'check-marker-cleared "marker still present"
                    #:fields `(("dir" . ,(path->string dir))))))

;; path-string -> path, ensure the dir holds .pm-incomplete. Idempotent:
;; creating the marker twice is the same as once, so a retried mark
;; after a kill is safe.
(define (mark-store-dir dir)
  (define d (if (path? dir) dir (string->path dir)))
  (make-directory* d)
  (call-with-output-file (marker-path d)
    (lambda (out) (void))
    #:exists 'truncate/replace)
  d)

;; path-string path-string -> path, atomic link flip for any target:
;; a temporary link is created beside the link name, then renamed over
;; it. Rename over an existing link is one atomic step: readers never
;; see a missing link, unlike delete-then-link.
(define (swap-link! target link)
  (define link-s (if (path? link) (path->string link) link))
  (define target-s (if (path? target) (path->string target) target))
  (define staging-link (string-append link-s ".tmp-"
                             (symbol->string (gensym 'store))))
  (when (or (file-exists? staging-link) (link-exists? staging-link))
    (delete-file staging-link))
  (make-file-or-directory-link target-s staging-link)
  (rename-file-or-directory staging-link link-s #t)
  (string->path link-s))

;; string string string path -> path, atomic current-link flip
(define (set-store-current state-root name slot versioned)
  (define link (build-path state-root "store" name slot "current"))
  (make-directory* (build-path state-root "store" name slot))
  (swap-link! versioned link))

;; ---------------------------------------------------------------------------
(module+ test
  (require rackunit
           racket/file
           racket/port
           "../errors/error-type.rkt")

  ;; All paths live below a synthetic state root (T-10); nothing here
  ;; reads the real home, the real XDG dirs, or the network.
  (define state-root (build-path (find-system-path 'temp-dir)
                                 "pm-store-test"))
  (when (directory-exists? state-root)
    (delete-directory/files state-root))
  (make-directory* state-root)

  ;; ensure creates the versioned dir with the marker already in it,
  ;; before the producer writes anything the test can observe.
  (define seen-during 'unseen)
  (define vdir
    (ensure-store-dir (path->string state-root)
                      "pkg-alpha" "default" "2.0" "9edb3f66fd80"
                      (lambda ()
                        (set! seen-during
                              (store-marker-present?
                               (build-path (path->string state-root)
                                           "store/pkg-alpha/default/2.0-9edb3f66fd80"))))))
  (check-true seen-during)
  (check-true (store-marker-present? vdir))
  (check-equal? (path->string vdir)
                (path->string (build-path (path->string state-root)
                                          "store/pkg-alpha/default/2.0-9edb3f66fd80")))

  ;; A failing producer keeps the marker and the error propagates.
  (check-pred exn:fail?
              (with-handlers ([exn:fail? (lambda (e) e)])
                (ensure-store-dir (path->string state-root)
                                  "pkg-fail" "default" "1.0" "8edb3f66fd80"
                                  (lambda () (error 'boom)))
                'no-error))
  (check-true
   (store-marker-present?
    (build-path (path->string state-root)
                "store/pkg-fail/default/1.0-8edb3f66fd80")))

  ;; A succeeding run clears the marker; the check passes after that.
  (clear-store-marker vdir)
  (check-false (store-marker-present? vdir))
  (check-not-exn (lambda () (check-marker-cleared vdir)))

  ;; The check fails closed while the marker stands.
  (check-pred install-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (check-marker-cleared
                 (build-path (path->string state-root)
                             "store/pkg-fail/default/1.0-8edb3f66fd80"))
                'no-error))

  ;; An existing dir with a marker is a dead run: kind 'config.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (ensure-store-dir (path->string state-root)
                                  "pkg-fail" "default" "1.0" "8edb3f66fd80"
                                  void)
                'no-error))

  ;; Two slots of one package get two dirs and two links.
  (define v-lts
    (ensure-store-dir (path->string state-root)
                      "pkg-alpha" "lts" "1.0" "7edb3f66fd80" void))
  (check-false (equal? vdir v-lts))
  (define link-current
    (set-store-current (path->string state-root)
                       "pkg-alpha" "default" vdir))
  (define link-lts
    (set-store-current (path->string state-root) "pkg-alpha" "lts" v-lts))
  (check-false (equal? link-current link-lts))
  (check-equal? (path->string (resolve-path link-current))
                (path->string vdir))

  ;; The flip is atomic: swapping twice lands on the second target.
  (define vdir2
    (ensure-store-dir (path->string state-root)
                      "pkg-alpha" "default" "2.1" "6edb3f66fd80" void))
  (clear-store-marker vdir2)
  (set-store-current (path->string state-root)
                     "pkg-alpha" "default" vdir2)
  (check-equal? (path->string (resolve-path link-current))
                (path->string vdir2))
  (delete-directory/files state-root))
