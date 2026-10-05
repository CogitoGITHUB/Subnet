;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2012-2026 Ludovic Courtès <ludo@gnu.org>
;;; Copyright © 2018 Jan Nieuwenhuizen <janneke@gnu.org>
;;; Copyright © 2019, 2020 Mathieu Othacehe <m.othacehe@gmail.com>
;;; Copyright © 2020 Florian Pelz <pelzflorian@pelzflorian.de>
;;; Copyright © 2020 Lars-Dominik Braun <ldb@leibniz-psychology.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.


(define-module (guix store)
  #:use-module (guix utils)
  #:use-module ((guix config) #:select (%store-directory %localstatedir))
  #:use-module (guix monads)
  #:use-module (guix base16)
  #:use-module (guix base32)
  #:autoload   (gcrypt hash) (sha256)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 match)
  #:export (%default-substitute-urls

            %store-monad
            store-return
            store-bind
            store-parameterize
            store-lift

            current-system
            set-current-system
            current-target-system
            set-current-target
            %guile-for-build

            %graft?
            set-grafting
            grafting?

            %store-prefix
            make-store-path
            output-path
            fixed-output-path
            store-path?
            direct-store-path?
            direct-store-path
            derivation-path?
            store-path-base
            store-path-package-name
            store-path-hash-part
            valid-store-name?
            valid-path-basename-syntax?
            valid-path-syntax?
            derivation-log-file))


(define %default-substitute-urls
  ;; Default list of substitute servers.
  '("https://bordeaux.guix.gnu.org"
    "https://ci.guix.gnu.org"))


;;;
;;; Store monad.
;;;

(define-syntax-rule (define-alias new old)
  (define-syntax new (identifier-syntax old)))

;; The store monad allows us to (1) build sequences of operations in the
;; store, and (2) make the store an implicit part of the execution context,
;; rather than a parameter of every single function.
(define-alias %store-monad %state-monad)
(define-alias store-return state-return)
(define-alias store-bind state-bind)
(define-alias store-parameterize state-parameterize)

;; Instantiate templates for %STORE-MONAD since it's syntactically different
;; from %STATE-MONAD.
(template-directory instantiations %store-monad)


(define (preserve-documentation original proc)
  "Return PROC with documentation taken from ORIGINAL."
  (set-object-property! proc 'documentation
                        (procedure-property original 'documentation))
  proc)

(define (store-lift proc)
  "Lift PROC, a procedure whose first argument is a connection to the store,
in the store monad."
  (preserve-documentation proc
                          (lambda args
                            (lambda (store)
                              (values (apply proc store args) store)))))


(define-inlinable (current-system)
  ;; Consult the %CURRENT-SYSTEM fluid at bind time.  This is equivalent to
  ;; (lift0 %current-system %store-monad), but inlinable, thus avoiding
  ;; closure allocation in some cases.
  (lambda (state)
    (values (%current-system) state)))

(define-inlinable (set-current-system system)
  ;; Set the %CURRENT-SYSTEM fluid at bind time.
  (lambda (state)
    (values (%current-system system) state)))

(define-inlinable (current-target-system)
  ;; Consult the %CURRENT-TARGET-SYSTEM fluid at bind time.
  (lambda (state)
    (values (%current-target-system) state)))

(define-inlinable (set-current-target target)
  ;; Set the %CURRENT-TARGET-SYSTEM fluid at bind time.
  (lambda (state)
    (values (%current-target-system target) state)))

(define %guile-for-build
  ;; The derivation of the Guile to be used within the build environment,
  ;; when using 'gexp->derivation' and co.
  (make-parameter #f))


(define %graft?
  ;; Whether to honor package grafts by default.
  (make-parameter #t))


(define-inlinable (set-grafting enable?)
  ;; This monadic procedure enables grafting when ENABLE? is true, and
  ;; disables it otherwise.  It returns the previous setting.
  (lambda (store)
    (values (%graft? enable?) store)))


(define-inlinable (grafting?)
  ;; Return a Boolean indicating whether grafting is enabled.
  (lambda (store)
    (values (%graft?) store)))


;;;


;;;
;;; Store paths.
;;;

(define %store-prefix
  ;; Absolute path to the Nix store.
  (make-parameter %store-directory))

(define (compressed-hash bv size)                 ; `compressHash'
  "Given the hash stored in BV, return a compressed version thereof that fits
in SIZE bytes."
  (define new (make-bytevector size 0))
  (define old-size (bytevector-length bv))
  (let loop ((i 0))
    (if (= i old-size)
        new
        (let* ((j (modulo i size))
               (o (bytevector-u8-ref new j)))
          (bytevector-u8-set! new j
                              (logxor o (bytevector-u8-ref bv i)))
          (loop (+ 1 i))))))

(define (make-store-path type hash name)          ; makeStorePath
  "Return the store path for NAME/HASH/TYPE."
  (let* ((s (string-append type ":sha256:"
                           (bytevector->base16-string hash) ":"
                           (%store-prefix) ":" name))
         (h (sha256 (string->utf8 s)))
         (c (compressed-hash h 20)))
    (string-append (%store-prefix) "/"
                   (bytevector->nix-base32-string c) "-"
                   name)))

(define (output-path output hash name)            ; makeOutputPath
  "Return an output path for OUTPUT (the name of the output as a string) of
the derivation called NAME with hash HASH."
  (make-store-path (string-append "output:" output) hash
                   (if (string=? output "out")
                       name
                       (string-append name "-" output))))

(define* (fixed-output-path name hash
                            #:key
                            (output "out")
                            (hash-algo 'sha256)
                            (recursive? #t))
  "Return an output path for the fixed output OUTPUT defined by HASH of type
HASH-ALGO, of the derivation NAME.  RECURSIVE? has the same meaning as for
'add-to-store'."
  (if (and recursive? (eq? hash-algo 'sha256))
      (make-store-path "source" hash name)
      (let ((tag (string-append "fixed:" output ":"
                                (if recursive? "r:" "")
                                (symbol->string hash-algo) ":"
                                (bytevector->base16-string hash) ":")))
        (make-store-path (string-append "output:" output)
                         (sha256 (string->utf8 tag))
                         name))))

(define (store-path? path)
  "Return #t if PATH is a store path.

This is a lightweight check.  Use 'valid-path-syntax?' to validate untrusted
input."
  ;; This is a lightweight check, compared to using a regexp, but this has to
  ;; be fast as it's called often in `derivation', for instance.
  ;; `isStorePath' in Nix does something similar.
  (string-prefix? (%store-prefix) path))

(define (direct-store-path? path)
  "Return #t if PATH is a store path, and not a sub-directory of a store path.
This predicate is sometimes needed because files *under* a store path are not
valid inputs."
  (and (store-path? path)
       (not (string=? path (%store-prefix)))
       (let ((len (+ 1 (string-length (%store-prefix)))))
         (not (string-index (substring path len) #\/)))))

(define (direct-store-path path)
  "Return the direct store path part of PATH, stripping components after
'/gnu/store/xxxx-foo'."
  (let ((prefix-length (+ (string-length (%store-prefix)) 35)))
    (if (> (string-length path) prefix-length)
        (let ((slash (string-index path #\/ prefix-length)))
          (if slash (string-take path slash) path))
        path)))

(define (derivation-path? path)
  "Return #t if PATH is a derivation path."
  (and (direct-store-path? path) (string-suffix? ".drv" path)))

(define (store-path-base path)
  "Return the base path of a path in the store."
  (and (string-prefix? (%store-prefix) path)
       (let ((base (string-drop path (+ 1 (string-length (%store-prefix))))))
         (and (> (string-length base) 33)
              (not (string-index base #\/))
              base))))

(define %store-item-charset
  ;; Valid characters for the name of a store item.
  (string->char-set (string-append "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                                   "abcdefghijklmnopqrstuvwxyz"
                                   "0123456789" "+-._?=")))

(define (valid-store-name? name)
  "Return true if NAME is syntactically a valid store file name--i.e., a name
that would be accepted by 'add-to-store' & co."
  ;; Like 'checkStoreName'.
  (and (not (string-null? name))
       (not (string-prefix? "." name))
       (string-every %store-item-charset name)))

(define (valid-path-basename-syntax? item)
  "Return true if ITEM has a valid syntax as the basename of a store item."
  (define hash-len 32)

  (and (> (string-length item) (+ hash-len 1))
       (string-every %nix-base32-charset item 0 hash-len)
       (eqv? (string-ref item hash-len) #\-)
       (valid-store-name? (string-drop item (+ hash-len 1)))))

(define (valid-path-syntax? path)
  "Return true if PATH is syntactically a valid store path.  Unlike
'store-path?', this can be used to validate untrusted input.

This must not be confused with 'valid-path?'."
  (define prefix-len
    (string-length (%store-prefix)))

  (and (> (string-length path) (+ prefix-len 1))
       (string-prefix? (%store-prefix) path)
       (eq? (string-ref path prefix-len) #\/)
       (valid-path-basename-syntax? (string-drop path (+ prefix-len 1)))))

(define (store-path-package-name path)
  "Return the package name part of PATH, a file name in the store."
  (let ((base (store-path-base path)))
    (string-drop base (+ 32 1)))) ;32 hash part + 1 hyphen

(define (store-path-hash-part path)
  "Return the hash part of PATH as a base32 string, or #f if PATH is not a
syntactically valid store path."
  (match (store-path-base path)
    (#f #f)
    (base
     (let ((hash (string-take base 32)))
       (and (string-every %nix-base32-charset hash)
            hash)))))

(define (derivation-log-file drv)
  "Return the build log file for DRV, a derivation file name, or #f if it
could not be found."
  (let* ((base    (basename drv))
         (log     (string-append (or (getenv "GUIX_LOG_DIRECTORY")
                                     (string-append %localstatedir "/log/guix"))
                                 "/drvs/"
                                 (string-take base 2) "/"
                                 (string-drop base 2)))
         (log.gz  (string-append log ".gz"))
         (log.bz2 (string-append log ".bz2")))
    (cond ((file-exists? log.gz) log.gz)
          ((file-exists? log.bz2) log.bz2)
          ((file-exists? log) log)
          (else #f))))
