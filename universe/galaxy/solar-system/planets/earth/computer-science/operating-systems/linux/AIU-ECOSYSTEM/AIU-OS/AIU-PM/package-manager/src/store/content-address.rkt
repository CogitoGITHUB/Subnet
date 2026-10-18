#lang racket/base
;; content-address.rkt -- a build's ADDRESS: the content hash of the
;; inputs a build actually takes, so that two builds of the same tree are
;; recognisably the same build and a third can be skipped.
;; (FEATURE-binary-cache.org, build-order step 25; plan/
;; new-components/binary-cache.org.)
;;
;; Two pure reads, no writing and no cache layout: tree-hash over a
;; directory tree, and build-input-address over what the executor is
;; handed. The reuse decision and the on-disk entries are
;; build/build-cache.rkt's job; keeping them apart is why this file is
;; one thing.
;;
;; ONE hash family: sha1 hex, the format spec/plan-hash.rkt already
;; established for the package-plan identity. Text parts hash through its
;; string-sha1hex; file bytes hash through openssl/sha1's sha1-bytes over
;; a binary port, the same algorithm and the same lowercase hex. A second
;; digest format in this project would be a defect, not a choice.
;;
;; WHAT THE ADDRESS COVERS, and what it deliberately does not. An address
;; that quietly omits an input is the exact bug this module exists to
;; prevent (FEATURE refusals: never a hit without a match), so the whole
;; list is here:
;;
;;   covered   the source tree, by CONTENT: every entry's path relative
;;             to the tree root, its mode, and its bytes (or, for a
;;             symlink, its target). A touch moves mtime only and leaves
;;             the address alone; a changed byte does not.
;;   covered   the recipe: the build steps in order, name and args, in
;;             the same encoding package-plan-canonical writes
;;             (spec/plan-hash.rkt), so an address and a plan agree on
;;             how a step is spelled.
;;   covered   the install prefix: it is baked into built artifacts.
;;   covered   the pinned toolchain: the host-tool list, and every
;;             environment pair the build runs with, except the three
;;             names below.
;;   excluded  the work dir, and the three location pointers build-env
;;             derives from it (HOME the staging fake, SRCDIR, BUILDDIR):
;;             they say WHERE the build ran, not WHAT it produced, and
;;             keying on them would give every run a fresh address, so
;;             the cache could never hit. A build that bakes those
;;             paths into its output is therefore not reusable; that
;;             limit is stated here rather than hidden.
;;   excluded  mtimes, owner, group, and the absolute path of the tree.
;;             Nothing is skipped for being a dotfile: an entry left out
;;             of the walk is an input the address pretends to cover.
;;
;; The FEATURE's open question -- one tree hash over path, mode and
;; content, or per-file digests combined -- is answered here: per-file
;; digests, combined, so there is one value to compare and the lines
;; under it still name every path when a digest disagrees.
;;
;; Refusals, both kind 'config, both naming what could not be hashed: a
;; tree that is not there, and an entry that cannot be read. An address
;; is never guessed: a caller that cannot get one must rebuild
;; (FEATURE: a build is never skipped when its hash could not be
;; computed).
;;
;; Paths: the tree is the one the caller hands over. No HOME, no XDG and
;; no find-system-path in this module.

(require racket/contract/base
         racket/file
         racket/list
         racket/path
         racket/string
         openssl/sha1
         "../errors/error-type.rkt"
         "../spec/spec.rkt"
         "../spec/plan-hash.rkt"
         "../narration/narration.rkt")

(provide
 (contract-out
  ;; path-string -> string, sha1 hex over the tree's content. Equal
  ;; inputs hash equal in any order, on any machine, forever.
  [tree-hash (-> path-string? string?)]
  ;; the executor's inputs -> string, sha1 hex over the canonical text
  ;; whose lines are listed in this file's header. #:tree-hash is the
  ;; digest tree-hash already returned: hashing once is the point.
  [build-input-address
   (->* (#:tree-hash string? #:steps (listof build-step?) #:prefix string?)
        (#:env (listof (cons/c string? string?)) #:tools (listof string?))
        string?)]))

;; ---------------------------------------------------------------------------
;; One digest, two shapes of input: text and bytes.

;; the algorithm name every hash in this project uses
(define digest-name "sha1")

;; path -> string, sha1 hex of the bytes on disk. The same algorithm and
;; hex as spec/plan-hash.rkt's string-sha1hex; read from a binary port so
;; a byte that is not valid text still hashes as itself.
(define (file-sha1hex p)
  (define in (open-input-file p #:mode 'binary))
  (dynamic-wind
   void
   (lambda () (bytes->hex-string (sha1-bytes in)))
   (lambda () (close-input-port in))))

;; path -> string, the mode bits, as text (stable across runs)
(define (mode-of p)
  (number->string (file-or-directory-permissions p)))

;; ---------------------------------------------------------------------------
;; The tree hash: per-file digests combined, sorted, one value out.

;; string string string -> string, one canonical line: kind, mode, fact.
(define (entry-line kind mode fact)
  (string-append kind " " mode " " fact))

;; path -> (listof (cons string string)), relative path and its line.
;; A symlink is hashed AS a link (its target, no mode bits, never
;; followed), so a link pointing back up the tree cannot make the walk
;; loop and a link's own name cannot hide the tree it points into.
(define (tree-entries root)
  (define (walk dir rel)
    (append*
     (for/list ([name (in-list (sort (directory-list dir) string<?))]
                #:unless (member name '("." "..")))
       (define full (build-path dir name))
       (define here
         (if (string=? rel "") name (string-append rel "/" name)))
       (cond
         [(link-exists? full)
          (list (cons here
                      (entry-line "l" "-"
                                  (path->string (read-symlink full)))))]
         [(directory-exists? full)
          (cons (cons here (entry-line "d" (mode-of full) ""))
                (walk full here))]
         [(file-exists? full)
          (list (cons here
                      (entry-line "f" (mode-of full) (file-sha1hex full))))]
         [else
          (raise-pm-error 'config 'tree-hash "tree entry is unreadable"
                          #:fields `(("path" . ,(path->string full))
                                     ("tree" . ,(path->string root)))
                          #:hint "the address cannot be computed, so the "
                          "build must run"))])))
  (walk root ""))

;; path-string -> string, sha1 hex over every entry's path, mode and
;; bytes. Sorted by path, so two machines that list one directory in
;; different orders still agree.
(define (tree-hash root)
  (define r (build-path (if (path? root) root (string->path root))))
  (unless (directory-exists? r)
    (raise-pm-error 'config 'tree-hash "no tree to hash"
                    #:fields `(("dir" . ,(path->string r)))
                    #:hint "hash the tree that is about to be built"))
  (define digest
    (string-sha1hex
     (string-join
      (for/list ([e (in-list (sort (tree-entries r) string<? #:key car))])
        (cdr e))
      "\n")))
  (step 'store "hash"
        (string-append digest-name " over every entry's path, mode and bytes")
        #:how digest
        #:inputs (list (path->string r)))
  digest)

;; ---------------------------------------------------------------------------
;; The address: the tree digest, the recipe, the prefix, the toolchain.
;; The first line is a format tag, so an entry written under an older
;; definition of this function can never be read as a hit under this one.

;; the three names build-env.rkt derives per run (HOME the staging fake,
;; SRCDIR, BUILDDIR): locations, not content
(define location-pointers '("HOME" "SRCDIR" "BUILDDIR"))

;; build-step -> string, name and args, the spelling plan-hash.rkt uses
(define (step-line s)
  (format "step ~a ~a"
          (build-step-name s)
          (string-join (for/list ([a (in-list (build-step-args s))])
                         (format "~s" a))
                       " ")))

;; the inputs the executor actually receives -> string, sha1 hex
(define (build-input-address #:tree-hash tree #:steps steps #:prefix prefix
                             #:env env #:tools tools)
  (define digest
    (string-sha1hex
     (string-join
      (append
       (list (format "address-format 1 algorithm ~a" digest-name)
             (format "tree ~a" tree))
       (for/list ([s (in-list steps)])
         (step-line s))
       (list (format "prefix ~a" prefix))
       (for/list ([p (in-list (sort env string<? #:key car))]
                  #:unless (member (car p) location-pointers))
         (format "env ~a=~a" (car p) (cdr p)))
       (for/list ([t (in-list (sort tools string<?))])
         (format "tool ~a" t)))
      "\n")))
  (step 'store "address"
        "sha1 over the tree, the recipe, the prefix and the toolchain"
        #:how digest
        #:inputs (list tree prefix))
  digest)

;; ---------------------------------------------------------------------------