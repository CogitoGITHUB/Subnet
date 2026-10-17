#lang racket/base
;; directories-test.rkt -- the moved-out test submodule of src/machine/directories.rkt.
;; Step 14 of TODO.org phase A: inline tests live under
;; package-manager/tests/, mirroring package-manager/src/ one
;; area to one area. The require list below is the module's OWN
;; list, redirected at src/ where it used to point at a sibling
;; area, plus the module itself: this body could already see
;; everything it uses, so nothing new can reach in.

(require rackunit
   racket/contract/base
            racket/runtime-path
            racket/string
            "../../src/errors/error-type.rkt"
         "../../src/machine/directories.rkt")

;; The pm checkout root the module builds its own paths from, reached the
;; same way from here: three ups, tests -> package-manager -> the pm root.
;; It was the module's own binding before the suite moved out, and the nu
;; cross-language case below reads gate/env.nu through it, so it must not
;; depend on the cwd.
(define-runtime-path checkout-dir "../../..")

(module+ test
  (require rackunit
           racket/file
           racket/system
           json
           "../../src/errors/error-type.rkt")

  ;; (listof (cons bytes bytes)) -> environment-variables, controlled env:
  ;; XDG_* from the cases below, HOME always set, PATH passed through so
  ;; the nu binary stays findable in the cross-language test
  (define (test-env pairs)
    (define ev (environment-variables-copy (current-environment-variables)))
    (for ([p (in-list pairs)])
      (environment-variables-set! ev (car p) (cdr p)))
    ev)

  (define ev-full
    (test-env (list (cons #"XDG_CONFIG_HOME" #"/tmp/pm-scope/config")
                    (cons #"XDG_CACHE_HOME" #"/tmp/pm-scope/cache")
                    (cons #"XDG_DATA_HOME" #"/tmp/pm-scope/data")
                    (cons #"HOME" #"/tmp/pm-scope/home"))))

  ;; XDG set: used verbatim.
  (check-equal?
   (parameterize ([current-environment-variables ev-full])
     (map path->string
          (list (roots-config (scope-roots 'user))
                (roots-cache (scope-roots 'user))
                (roots-data (scope-roots 'user)))))
   '("/tmp/pm-scope/config" "/tmp/pm-scope/cache" "/tmp/pm-scope/data"))

  ;; XDG unset: HOME fallbacks. The live environment carries real
  ;; XDG_CONFIG_HOME and XDG_DATA_HOME, so they are explicitly removed
  ;; here (#f unbinds); otherwise the test would measure the room, not
  ;; the fallback.
  (define ev-home-only
    (test-env (list (cons #"XDG_CONFIG_HOME" #f)
                    (cons #"XDG_CACHE_HOME" #f)
                    (cons #"XDG_DATA_HOME" #f)
                    (cons #"HOME" #"/tmp/pm-scope/home"))))
  (check-equal?
   (parameterize ([current-environment-variables ev-home-only])
     (map path->string
          (list (roots-config (scope-roots 'user))
                (roots-cache (scope-roots 'user))
                (roots-data (scope-roots 'user)))))
   '("/tmp/pm-scope/home/.config"
     "/tmp/pm-scope/home/.cache"
     "/tmp/pm-scope/home/.local/share"))

  ;; Blank counts as unset, like the Nu side.
  (define ev-blank
    (test-env (list (cons #"XDG_CACHE_HOME" #"   ")
                    (cons #"HOME" #"/tmp/pm-scope/home"))))
  (check-equal?
   (parameterize ([current-environment-variables ev-blank])
     (path->string (roots-cache (scope-roots 'user))))
   "/tmp/pm-scope/home/.cache")

  ;; Anything but user scope is deferred, kind 'config.
  (check-pred config-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (scope-roots 'system)
                'no-error))

  ;; Both implementations resolve identical roots for the user scope:
  ;; the same controlled env drives Racket above and nu below (nu reads
  ;; its own process env, which carries the parameterized table). nu runs
  ;; behind sh: Racket exports PWD with a trailing slash, which this nu
  ;; refuses, so sh resets the directory first and execs (measured).
  (define sh-bin
    (or (find-executable-path "sh")
        (error 'scope-test "sh not found")))
  (define nu-bin
    (or (find-executable-path "nu")
        (let ((pinned (build-path (find-system-path 'home-dir)
                                  "opt" "nushell" "0.116.1" "nu")))
          (and (file-exists? pinned) pinned))
        (error 'scope-test "nu binary not found")))
  ;; The checkout dir without a trailing slash, so the absolute `use`
  ;; path below never depends on the cwd nu starts in.
  (define here-dirs
    (let ((d (path->string (simplify-path checkout-dir))))
      (if (and (> (string-length d) 1)
               (string-suffix? d "/"))
          (substring d 0 (- (string-length d) 1))
          d)))
  (define nu-json (build-path (find-system-path 'temp-dir)
                              "pm-scope-nu.json"))
  (define nu-log (build-path (find-system-path 'temp-dir)
                              "pm-scope-nu.log"))
  (when (file-exists? nu-json) (delete-file nu-json))
  (define nu-out (open-output-file nu-log #:exists 'truncate/replace))
  (define nu-err (open-output-file (string-append (path->string nu-log)
                                                  ".err")
                                   #:exists 'truncate/replace))
  (define nu-in (open-input-file "/dev/null"))
  (define nu-prog
    (string-append "use " here-dirs
                   "/gate/env.nu [scope-roots]; scope-roots | to json | save "
                   (path->string nu-json)))
  (define nu-shell
    (string-append "cd /tmp && exec " (path->string nu-bin)
                   " --no-config-file -c '" nu-prog "'"))
  (define nu-r
    (parameterize ([current-environment-variables ev-full])
      (process*/ports nu-out nu-in nu-err
                      (path->string sh-bin)
                      "-c" nu-shell)))
  (close-input-port nu-in)
  ((list-ref nu-r 4) 'wait)
  (define nu-code ((list-ref nu-r 4) 'exit-code))
  (close-output-port nu-out)
  (close-output-port nu-err)
  (check-equal? nu-code 0)
  (define nu-roots
    (call-with-input-file nu-json read-json))
  (delete-file nu-json)
  (delete-file nu-log)
  (delete-file (string-append (path->string nu-log) ".err"))
  (check-equal?
   (parameterize ([current-environment-variables ev-full])
     (map path->string
          (list (roots-config (scope-roots 'user))
                (roots-cache (scope-roots 'user))
                (roots-data (scope-roots 'user)))))
   (list (hash-ref nu-roots 'config)
         (hash-ref nu-roots 'cache)
         (hash-ref nu-roots 'data)))

  ;; G-06: explicit dirs first in order, then config, then data. No
  ;; network source exists anywhere in the answer.
  (check-equal?
   (parameterize ([current-environment-variables ev-full])
     (map path->string (spec-search-roots '("/x/specs" "/y/specs"))))
   '("/x/specs" "/y/specs"
     "/tmp/pm-scope/config/aiu-pm/specs"
     "/tmp/pm-scope/data/aiu-pm/specs"))
  ;; Duplicates collapse, order kept; empty explicit still yields the two.
  (check-equal?
   (parameterize ([current-environment-variables ev-full])
     (map path->string
          (spec-search-roots '("/x/specs" "/x/specs"))))
   '("/x/specs"
     "/tmp/pm-scope/config/aiu-pm/specs"
     "/tmp/pm-scope/data/aiu-pm/specs"))
  (check-equal?
   (parameterize ([current-environment-variables ev-full])
     (map path->string (spec-search-roots '())))
   '("/tmp/pm-scope/config/aiu-pm/specs"
     "/tmp/pm-scope/data/aiu-pm/specs")))

