#lang racket/base
;; build-cache-test.rkt -- the moved-out test submodule of
;; src/build/build-cache.rkt. Step 14 of TODO.org phase A: inline tests
;; live under package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN list,
;; redirected at src/, plus the module itself -- and ONE addition:
;; ../../src/store/content-address.rkt, because a cache test has to put
;; a REAL tree-hash on the table as HASH-OF. That is what the injection
;; buys: build/ may not require store/ under gate/
;; one-way-dependency-lint.nu, so the caller that may see both areas
;; passes the hash in.
;;
;; TODO.org step 25, the whole of "done when": a second build of the
;; same inputs HITS the cache. The hit is asserted directly, from the
;; values cache-with-build answers with AND from a counter inside the
;; build: a cache that rebuilt and compared afterwards would leave the
;; counter at two, and the second half of the hit check fails it.

(require rackunit
         racket/contract/base
         racket/file
         racket/path
         racket/string
         "../../src/errors/error-type.rkt"
         "../../src/narration/narration.rkt"
         "../../src/store/content-address.rkt"
         "../../src/build/build-cache.rkt")

(module+ test
  (require rackunit)

  (define root (make-temporary-directory "pm-buildcache~a"))
  (define cache-root (build-path root "cache"))
  (define src (build-path root "src"))

  ;; The source tree, written so its content is fixed and its mtimes are
  ;; whatever the build happened to do.
  (define main-bytes #"int main(void) { return 0; }\n")
  (define (write-main bytes)
    (call-with-output-file (build-path src "main.c")
      (lambda (out) (write-bytes bytes out))
      #:exists 'truncate/replace)
    (chmod (build-path src "main.c") #o644))

  (make-directory* src)
  (write-main main-bytes)

  (define steps (list (build-step 'cc '("-c" "-o" "main.o" "main.c"))))
  (define prefix "/opt/demo")
  (define env '(("LANG" . "C") ("HOME" . "/run/one") ("SRCDIR" . "/run/one/src")
                ("BUILDDIR" . "/run/one/build")))
  (define tools '("cc"))

  (define (address-of tree)
    (build-input-address #:tree-hash (tree-hash tree) #:steps steps
                         #:prefix prefix #:env env #:tools tools))

  ;; The build stands in for the executor. It COUNTS itself, which is
  ;; the half of a hit that a returned boolean cannot show.
  (define builds 0)
  (define (fake-build into)
    (set! builds (add1 builds))
    (call-with-output-file (build-path into "main.o")
      (lambda (out) (display "ELF-ish object bytes\n" out))
      #:exists 'truncate/replace)
    into)

  ;; ---------------------------------------------------------------------------
  ;; (c) The address is stable across two runs over one tree, and it is
  ;; the key the lookup then compares: one tree, one address, spelled
  ;; the same way twice.
  (define address-1 (address-of src))
  (check-equal? (address-of src) address-1)

  ;; (a) FIRST BUILD: a miss, and the build really ran.
  (define-values (first-hit first-tree)
    (cache-with-build cache-root address-1 fake-build tree-hash))
  (check-false first-hit)
  (check-equal? builds 1)
  (check-pred path? first-tree)
  (check-true (file-exists? (build-path first-tree "main.o")))

  ;; (a) SECOND BUILD OF THE SAME INPUTS: THE HIT. Asserted both ways --
  ;; the cache says it served, and the executor says it did not run.
  (define-values (second-hit second-tree)
    (cache-with-build cache-root address-1 fake-build tree-hash))
  (check-true second-hit "a second build of the same inputs must hit the cache")
  (check-equal? builds 1 "a hit must not run the executor again")
  (check-pred path? second-tree)
  ;; The tree handed back is the cache's OWN, not a fresh build: the path
  ;; is the one the entry was filed under, artifact and all.
  (check-equal? (path->string second-tree)
                (path->string (build-path (cache-entry-dir cache-root address-1)
                                          "artifact")))
  (check-true (file-exists? (build-path second-tree "main.o")))

  ;; cache-lookup answers the same question on its own: the stored tree
  ;; on a hit, nothing at all on a miss.
  (define looked-up (cache-lookup cache-root address-1 tree-hash))
  (check-pred path? looked-up)
  (check-equal? (path->string looked-up) (path->string second-tree))
  ;; An address no entry has ever filed is a miss on the first test of
  ;; all: the leaf is simply not on disk. The FIRST hex character is
  ;; what decides the leaf, so that is what is changed here -- appending
  ;; would leave the leaf alone and only change the recorded address.
  (define address-absent
    (string-append (if (string=? (substring address-1 0 1) "0") "1" "0")
                    (substring address-1 1)))
  (check-false (cache-lookup cache-root address-absent tree-hash))

  ;; (b1) A TOUCH with identical bytes: the address does not move, so the
  ;; cache is asked for the one it already holds and serves it. This is
  ;; the check a mtime key fails.
  (file-or-directory-mtouch (build-path src "main.c"))
  (define address-touched (address-of src))
  (check-equal? address-touched address-1)
  (check-pred path? (cache-lookup cache-root address-touched tree-hash))
  (define-values (touch-hit touch-tree)
    (cache-with-build cache-root address-touched fake-build tree-hash))
  (check-true touch-hit "a touch moves mtime only; the inputs are the same")
  (check-equal? builds 1 "a touched tree with identical bytes is still a hit")
  (check-pred path? touch-tree)

  ;; (b2) A CHANGED BYTE: a different address, so a MISS -- and the
  ;; cache does not answer from what it happens to hold.
  (write-main #"int main(void) { return 1; }\n")
  (define address-2 (address-of src))
  (check-not-equal? address-2 address-1)
  (check-false (cache-lookup cache-root address-2 tree-hash))
  (define-values (third-hit third-tree)
    (cache-with-build cache-root address-2 fake-build tree-hash))
  (check-false third-hit)
  (check-pred path? third-tree)
  (check-true (file-exists? (build-path third-tree "main.o")))
  (check-equal? builds 2 "a changed byte must rebuild")

  ;; The first entry is still there and still good: a second address did
  ;; not displace the first, because entries are filed BY address.
  (check-pred path? (cache-lookup cache-root address-1 tree-hash))
  (check-equal? builds 2)

  ;; ---------------------------------------------------------------------------
  ;; Never a hit without a match. Each of these is answered as a MISS,
  ;; never as a hit and never as a raised error.
  (define entry-1 (cache-entry-dir cache-root address-1))

  ;; A damaged record reads as nothing rather than as a hit.
  (call-with-output-file (build-path entry-1 "entry.rktd")
    (lambda (out) (display "this is not a record\n" out))
    #:exists 'truncate/replace)
  (check-false (cache-lookup cache-root address-1 tree-hash))

  ;; A record that claims another address is not a hit for this one.
  (call-with-output-file (build-path entry-1 "entry.rktd")
    (lambda (out) (writeln (list 'entry address-2 (tree-hash
                                                   (build-path entry-1
                                                             "artifact")))
                           out))
    #:exists 'truncate/replace)
  (check-false (cache-lookup cache-root address-1 tree-hash))

  ;; A stored tree whose bytes no longer hash to its record is not a hit
  ;; either: the cache is never a source of truth, so it re-reads.
  (call-with-output-file (build-path entry-1 "entry.rktd")
    (lambda (out)
      (writeln (list 'entry address-1 "0000000000000000000000000000000000000000")
               out))
    #:exists 'truncate/replace)
  (check-false (cache-lookup cache-root address-1 tree-hash))

  ;; An entry with no stored tree at all is a miss, not a raise.
  (delete-directory/files (build-path entry-1 "artifact"))
  (call-with-output-file (build-path entry-1 "entry.rktd")
    (lambda (out)
      (writeln (list 'entry address-1 (tree-hash src)) out))
    #:exists 'truncate/replace)
  (check-false (cache-lookup cache-root address-1 tree-hash))

  ;; And after all that damage the cache still serves a sound rebuild,
  ;; because an entry it cannot trust is one it replaces.
  (define-values (repair-hit repair-tree)
    (cache-with-build cache-root address-1 fake-build tree-hash))
  (check-false repair-hit)
  (check-pred path? (cache-lookup cache-root address-1 tree-hash))
  (check-true (file-exists? (build-path repair-tree "main.o")))

  ;; ---------------------------------------------------------------------------
  ;; The cache writes where the project writes: under the CACHE ROOT the
  ;; caller derives from the scope seam, in the app dir beside the data
  ;; root's aiu-pm/, and never into the source tree.
  (define entries-root
    (build-path (path->string cache-root) "aiu-pm" "build-cache" "entries"))
  (check-equal? (path->string (simplify-path (build-path entry-1 'up)))
                (path->string (simplify-path entries-root)))
  (check-false (string-contains? (path->string entry-1) (path->string src)))
  (check-false (directory-exists? (build-path src "aiu-pm")))

  (delete-directory/files root))
