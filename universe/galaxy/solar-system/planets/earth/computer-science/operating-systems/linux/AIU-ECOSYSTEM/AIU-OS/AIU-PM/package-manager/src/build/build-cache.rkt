#lang racket/base
;; build-cache.rkt -- the reuse decision: do we ALREADY have this exact
;; build? On a hit the executor is skipped and the stored tree is handed
;; back; on a miss the build runs once and what it produced is filed
;; under the address it was built from. (FEATURE-binary-cache.org;
;; plan/new-components/binary-cache.org, step 25.)
;;
;; The address arrives already computed. build/ may not require store/
;; under the one-way ledger (gate/one-way-dependency-lint.nu, MAY_USE
;; build: process errors narration spec -- store is not on it, and
;; FEATURE-binary-cache.org's "build sits above store" is not in that
;; table yet), so the dependency is inverted instead of broken: the
;; caller that may see both areas hashes the tree with
;; store/content-address.rkt and hands the digest over. That is also why
;; hash-of is a parameter rather than a call: one hashing implementation
;; in this project, injected, never copied. The ledger line this wants
;; is one row in that table; until it is added the inversion stands.
;;
;; HASH-OF is the caller's tree-hash: (path-string? . ->. string?). It
;; is used twice and nowhere else, both times to answer the only
;; question a cache may be asked: do these bytes still hash to what the
;; entry says they hash to.
;;
;; WHAT THE KEY IS. The address, and nothing else, and the address is
;; computed over the source tree's content, the recipe, the prefix and
;; the pinned toolchain (store/content-address.rkt lists every covered
;; and excluded input). This file never widens or narrows that set, and
;; it never keys on mtime, on the work dir or on the tree's path: a key
;; that added one of those would miss every time it should hit.
;;
;; NEVER A HIT WITHOUT A MATCH. A hit requires an entry that exists, whose
;; recorded address is the one asked for, and whose stored tree STILL
;; hashes to the digest recorded when it was filed. Anything else -- a
;; missing record, a short read, a digest that disagrees -- is narrated
;; as a WARN and answered as a MISS, never as a failure and never as a
;; hit (FEATURE refusals). A cache that guesses here installs the wrong
;; bytes and blames the package.
;;
;; WRITES. Every write goes under the cache root the caller derives from
;; the scope seam (D-029, machine/directories.rkt's roots-cache), never
;; into the source tree, and every one of them is inside
;; store-artifact! -- the single choke point, so there is exactly one
;; place to audit. An entry is built in staging and moved into place with
;; one rename, so a reader sees either no entry or a whole one, and a
;; killed run leaves a staging dir rather than a half entry. The live
;; vault lock is never in this path, and never overwritten.
;;
;; REBUILD IS NEVER AN ERROR. Nothing here reaches the network, and a miss
;; only costs a build.

(require racket/contract/base
         racket/file
         racket/path
         racket/string
         "../errors/error-type.rkt"
         "../narration/narration.rkt")

(provide
 (contract-out
  ;; cache-root address -> path, where the entry for ADDRESS lives. The
  ;; documents layer names this path as the cache-entry field.
  [cache-entry-dir (-> path-string? string? path?)]
  ;; cache-root address hash-of -> the stored tree on a hit, #f on a
  ;; miss. Never raises on a damaged entry: that is a narrated miss.
  [cache-lookup
   (->* (path-string? string? (-> path-string? string?))
        ((or/c path? #f)))]
  ;; cache-root address produce hash-of -> (values cached? tree). The
  ;; decision, with the build inside it: PRODUCE is handed a staging tree
  ;; to build into on a miss and is never called on a hit -- that is what
  ;; makes a hit a hit and not a rebuild that compares afterwards. The
  ;; returned tree is the cache's own on a hit and the fresh one on a
  ;; miss; either way it is the artifact this build would have produced.
  [cache-with-build
   (->* (path-string? string? (-> path? path?) (-> path-string? string?))
        ((values boolean? path?)))]))

;; ---------------------------------------------------------------------------
;; Where entries live: <cache-root>/aiu-pm/build-cache/{entries,staging},
;; the app dir under the cache root, exactly as the data root carries
;; aiu-pm/events and aiu-pm/vault.

(define (cache-dir cache-root)
  (build-path (path-string cache-root) "aiu-pm" "build-cache"))

(define (entries-dir cache-root)
  (build-path (cache-dir cache-root) "entries"))

(define (staging-dir cache-root)
  (build-path (cache-dir cache-root) "staging"))

;; the leaf an address is filed under. Twelve hex characters, the width
;; package-plan-store-dir already uses (spec/plan-hash.rkt, D-023): a
;; short leaf keeps the tree browsable, and a collision is caught by the
;; recorded address check rather than by pretending 12 hex cannot clash.
(define (address-leaf address)
  (substring address 0 (min 12 (string-length address))))

(define artifact-leaf "artifact")
(define record-leaf "entry.rktd")

(define (cache-entry-dir cache-root address)
  (build-path (entries-dir cache-root) (address-leaf address)))

;; ---------------------------------------------------------------------------
;; The entry record: (entry ADDRESS ARTIFACT-DIGEST), plain data, written
;; once when the entry is filed. ARTIFACT-DIGEST is the digest of the
;; tree as stored, so a later verify can re-hash and name both sides; the
;; source tree's own digest is not repeated here, because ADDRESS already
;; commits to it.

(struct entry-record (address artifact-digest) #:transparent)

;; any -> (or/c entry-record #f), one datum or nothing
(define (read-record d)
  (and (list? d)
       (= (length d) 3)
       (eq? (car d) 'entry)
       (andmap string? (cdr d))
       (entry-record (cadr d) (caddr d))))

;; path -> (or/c entry-record #f), a damaged or missing record reads as
;; nothing, which the caller answers as a miss
(define (load-record entry)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define in (open-input-file (build-path entry record-leaf)))
    (dynamic-wind
     void
     (lambda () (read-record (read in)))
     (lambda () (close-input-port in)))))

;; ---------------------------------------------------------------------------
;; Lookup: the only place a hit is claimed.

;; path-string string (-> path-string? string?) -> (or/c path #f)
(define (cache-lookup cache-root address hash-of)
  (define entry (cache-entry-dir cache-root address))
  (cond
    [(not (directory-exists? entry)) #f]
    [else
     (define rec (load-record entry))
     (define tree (build-path entry artifact-leaf))
     (cond
       [(not rec)
        (warn 'build (string-append (path->string entry)
                                    ": no readable record; the entry is not trusted"))
        #f]
       [(not (string=? (entry-record-address rec) address))
        (warn 'build
              (string-append (path->string entry)
                             ": this leaf records another address ("
                             (entry-record-address rec) " vs " address
                             "); the entry is not trusted"))
        #f]
       [(not (directory-exists? tree))
        (warn 'build
              (string-append (path->string tree)
                             ": the entry has no stored tree; it is not trusted"))
        #f]
       [else
        ;; The re-hash: a cache is never a source of truth, so the bytes
        ;; are read again and compared before they are handed out.
        (define on-disk (hash-of tree))
        (if (string=? on-disk (entry-record-artifact-digest rec))
            (begin
              (step 'build "cache-hit"
                    "the stored tree re-hashes to the digest recorded for it"
                    #:how address
                    #:inputs (list on-disk))
              tree)
            (begin
              (warn 'build
                    (string-append (path->string tree)
                                   ": the stored tree does not hash to its record ("
                                   (entry-record-artifact-digest rec)
                                   " recorded, " on-disk
                                   " on disk); the entry is not trusted"))
              #f))])]))

;; ---------------------------------------------------------------------------
;; Store: the one write choke point in this file.

;; cache-root address built-tree digest -> path, file what the build
;; produced under ADDRESS and answer the entry. The staging entry gets
;; the built bytes AND the record before the rename, so an entry is
;; never visible without the digest that vouches for it.
(define (store-artifact! cache-root address built-tree digest)
  (define staging-entry
    (build-path (staging-dir cache-root)
                (symbol->string (gensym "entry"))))
  (define entry (cache-entry-dir cache-root address))
  (make-directory* staging-entry)
  (rename-file-or-directory built-tree
                             (build-path staging-entry artifact-leaf))
  (write-record! staging-entry address digest)
  (make-directory* (entries-dir cache-root))
  ;; An entry for this address is either absent or one whose bytes did
  ;; not hash to its record -- the caller is here because it missed -- so
  ;; replacing it is the whole repair. Content addressing makes the
  ;; replacement harmless: both sides claim the same inputs.
  (when (directory-exists? entry)
    (delete-directory/files entry))
  (rename-file-or-directory staging-entry entry)
  (step 'build "cache-store"
        "the built tree is filed under the address it was built from"
        #:how address
        #:inputs (list (path->string entry)))
  entry)

;; path string string -> void, the record beside the stored tree
(define (write-record! staging-entry address digest)
  (call-with-output-file (build-path staging-entry record-leaf)
    (lambda (out)
      (write (list 'entry address digest) out)
      (newline out))
    #:exists 'truncate/replace))

;; ---------------------------------------------------------------------------
;; The decision.

;; cache-root string (-> path? path?) (-> path-string? string?)
;;   -> (values boolean? path)
(define (cache-with-build cache-root address produce hash-of)
  ;; The lookup gets HASH-OF: without it there is no re-hash to do, and
  ;; a hit would rest on the record alone, which is the guess this file
  ;; refuses to make (NEVER A HIT WITHOUT A MATCH).
  (define hit (cache-lookup cache-root address hash-of))
  (if hit
      (begin
        (decide 'build "reuse"
                "the cache already holds a tree for these exact inputs"
                #:chosen hit
                #:alternatives '("rebuild"))
        (skip 'build (path->string hit)
              "the executor does not run; the stored tree is reused")
        (values #t hit))
      (let* ([staging-tree
              (build-path (staging-dir cache-root)
                          (build-path (symbol->string (gensym "tree"))
                                      artifact-leaf))]
             ;; the tree is there before the build starts: a step that
             ;; copies into it must find the directory waiting
             [built (begin (make-directory* staging-tree)
                           (produce staging-tree))]
             ;; the digest is over what the build produced, which is not
             ;; necessarily the path it was handed
             [digest (hash-of built)]
             [entry (store-artifact! cache-root address built digest)])
        (decide 'build "rebuild"
                "no cache entry holds these inputs, so the build ran once"
                #:chosen entry
                #:alternatives '("reuse"))
        (values #f (build-path entry artifact-leaf)))))

;; ---------------------------------------------------------------------------
