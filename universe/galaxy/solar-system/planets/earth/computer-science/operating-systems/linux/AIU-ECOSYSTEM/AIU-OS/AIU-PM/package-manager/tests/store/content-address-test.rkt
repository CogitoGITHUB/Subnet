#lang racket/base
;; content-address-test.rkt -- the moved-out test submodule of
;; src/store/content-address.rkt. Step 14 of TODO.org phase A: inline
;; tests live under package-manager/tests/, mirroring
;; package-manager/src/ one area to one area. The require list below is
;; the module's OWN list, redirected at src/, plus the module itself:
;; this body could already see everything it uses, so nothing new can
;; reach in.
;;
;; TODO.org step 25 (binary cache) asks three things of an address, and
;; each is a check below: a second run over one tree is the SAME address,
;; a touch with identical bytes does not move it, and a changed byte or
;; a changed PATH does. The last one is the one a lazy key omits.

(require rackunit
         racket/contract/base
         racket/file
         racket/list
         racket/path
         racket/string
         openssl/sha1
         "../../src/errors/error-type.rkt"
         "../../src/spec/spec.rkt"
         "../../src/spec/plan-hash.rkt"
         "../../src/narration/narration.rkt"
         "../../src/store/content-address.rkt")

(module+ test
  (require rackunit)

  (define root (make-temporary-directory "pm-contentaddress~a"))
  (define tree-a (build-path root "tree-a"))
  (define tree-b (build-path root "tree-b"))

  ;; A tree written the same way every time, so a difference in a digest
  ;; is about the CONTENT and never about the umask that created it.
  (define (write-tree into files)
    (for ([f (in-list files)])
      (define full (build-path into (car f)))
      (make-directory* (build-path full 'up))
      (call-with-output-file full
        (lambda (out) (write-bytes (cdr f) out))
        #:exists 'truncate/replace)
      (chmod full #o644)))

  (define main-bytes #"int main(void) { return 0; }\n")
  (define util-bytes #"int util(void) { return 1; }\n")
  (define files
    '(("main.c" . ,main-bytes)
      ("src/util.c" . ,util-bytes)))

  (write-tree tree-a files)
  (write-tree tree-b files)

  ;; (c) STABILITY: the same tree hashed twice is one address, and so is
  ;; the same CONTENT under a different absolute path -- the tree's own
  ;; location is excluded, or no two checkouts would ever share a cache.
  (define digest-a-1 (tree-hash tree-a))
  (define digest-a-2 (tree-hash tree-a))
  (check-equal? digest-a-1 digest-a-2)
  (check-equal? (tree-hash tree-b) digest-a-1)

  ;; (b1) A TOUCH with identical bytes does not move the address: mtime
  ;; is not an input, and a key that read it would miss on every build.
  (file-or-directory-mtouch (build-path tree-a "main.c"))
  (check-equal? (tree-hash tree-a) digest-a-1)
  (file-or-directory-mtouch (build-path tree-a "src/util.c"))
  (check-equal? (tree-hash tree-a) digest-a-1)

  ;; (b2) A CHANGED BYTE does move it. Same length, one byte different,
  ;; so the difference cannot be an artefact of the file's size.
  (call-with-output-file (build-path tree-a "main.c")
    (lambda (out) (write-bytes #"int main(void) { return 1; }\n" out))
    #:exists 'truncate/replace)
  (chmod (build-path tree-a "main.c") #o644)
  (define digest-a-changed (tree-hash tree-a))
  (check-not-equal? digest-a-changed digest-a-1)
  ;; And it agrees with a tree that never held the old bytes: the change
  ;; is seen, not merely noticed.
  (check-equal? digest-a-changed
               (tree-hash
                (begin
                  (write-tree tree-b '(("main.c" . #"int main(void) { return 1; }\n")
                                       ("src/util.c" . ,util-bytes)))
                  tree-b)))

  ;; A PATH is an input. Two trees holding the same bytes under the same
  ;; names are one build, and moving ONE name makes them two -- an
  ;; address that dropped the name would call them the same build, which
  ;; is the silent omission this module exists to prevent. Checked on
  ;; both sides, because the second half alone also passes for a key
  ;; that hashed nothing about names at all.
  (define renamed (build-path root "tree-rename"))
  (write-tree renamed files)
  (check-equal? (tree-hash renamed) digest-a-1
                "same bytes under the same names are one build")
  (rename-file-or-directory (build-path renamed "main.c")
                            (build-path renamed "entry.c"))
  (check-not-equal? (tree-hash renamed) digest-a-1
                    "moving a byte under another name is a different build")

  ;; An ADDED file moves it too, and nothing is skipped for being a
  ;; dotfile: an entry left out of the walk is an input the address
  ;; pretends to cover.
  (write-tree tree-b '(("main.c" . #"int main(void) { return 1; }\n")
                       ("src/util.c" . ,util-bytes)
                       (".hidden" . #"x")))
  (check-not-equal? (tree-hash tree-b) digest-a-changed)

  ;; A symlink is hashed AS a link: its target, no mode bits, never
  ;; followed. A DANGLING one therefore still moves the address -- a walk
  ;; that skipped it would call the two trees the same build.
  (define linked (build-path root "tree-link"))
  (define plain (build-path root "tree-plain"))
  (write-tree linked files)
  (write-tree plain files)
  (check-equal? (tree-hash linked) (tree-hash plain))
  (make-symlink "nowhere/at/all" (build-path linked "dangling"))
  (check-not-equal? (tree-hash linked) (tree-hash plain))
  ;; Change the TARGET, not the bytes, and the address moves: what a link
  ;; says is an input too.
  (delete-file (build-path linked "dangling"))
  (make-symlink "somewhere/else" (build-path linked "dangling"))
  (check-not-equal? (tree-hash linked) (tree-hash plain))

  ;; A tree that is not there cannot be addressed, and the refusal names
  ;; what could not be hashed: a caller that cannot get an address must
  ;; rebuild (FEATURE: never skip a build whose hash could not be made).
  (define missing
    (with-handlers ([exn:fail:pm? (lambda (e) e)])
      (tree-hash (build-path root "no-such-tree"))
      'no-error))
  (check-pred config-error? missing)
  (check-equal? (pm-error-exit-code missing) 78)
  (check-regexp-match #rx"no tree to hash" (exn-message missing))

  ;; ---------------------------------------------------------------------------
  ;; build-input-address: the tree digest, the recipe, the prefix and the
  ;; pinned toolchain, and nothing else.

  (define steps (list (build-step 'cc '("-c" "-o" "main.o" "main.c"))))
  (define prefix "/opt/demo")
  (define env '(("LANG" . "C") ("HOME" . "/run/one") ("SRCDIR" . "/run/one/src")
                ("BUILDDIR" . "/run/one/build")))
  (define tools '("cc" "ld"))

  ;; the address of one explicit set of inputs; every check below names
  ;; the ONE input it moves, so a failure names the omission
  (define (address th given-steps given-prefix given-env given-tools)
    (build-input-address #:tree-hash th #:steps given-steps
                         #:prefix given-prefix #:env given-env
                         #:tools given-tools))

  (define (stock-address th) (address th steps prefix env tools))

  ;; (c) The address is stable across two runs over the same inputs.
  (define addr-1 (stock-address digest-a-1))
  (check-equal? (stock-address digest-a-1) addr-1)
  ;; The ORDER of the env and tool lists is not content either.
  (check-equal? (address digest-a-1 steps prefix (reverse env) (reverse tools))
                addr-1)

  ;; Each covered input moves the address on its own: the tree digest,
  ;; the recipe, the prefix, the pinned toolchain, and any env pair that
  ;; is not one of the three location pointers.
  (check-not-equal? (stock-address digest-a-changed) addr-1)
  (check-not-equal? (address digest-a-1
                                 (list (build-step 'cc '("-c" "main.c")))
                                 prefix env tools)
                    addr-1)
  (check-not-equal? (address digest-a-1 steps "/opt/other" env tools) addr-1)
  (check-not-equal? (address digest-a-1 steps prefix env
                                 (list "cc" "ld" "ar"))
                    addr-1)
  (check-not-equal? (address digest-a-1 steps prefix
                                 (cons '("LANG" . "en_US") env) tools)
                    addr-1)

  ;; The EXCLUSIONS are checked too, and this is the one that keeps the
  ;; cache usable: HOME, SRCDIR and BUILDDIR say WHERE the build ran.
  ;; Keyed on, every run would get a fresh address and the cache could
  ;; never hit, which is why they are named in the module's header.
  (check-equal? (address digest-a-1 steps prefix
                                 '(("LANG" . "C")
                                   ("HOME" . "/run/two")
                                   ("SRCDIR" . "/run/two/src")
                                   ("BUILDDIR" . "/run/two/build"))
                                 tools)
                addr-1)

  (delete-directory/files root))
