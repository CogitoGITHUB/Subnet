;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2013-2022, 2025 Ludovic Courtès <ludo@gnu.org>
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

(define-module (guix tests)
  #:use-module ((guix config) #:select (%storedir %localstatedir))
  #:use-module (guix store)
  #:use-module (guix derivations)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix base32)
  #:use-module (guix serialization)
  #:use-module (guix monads)
  #:use-module ((guix utils) #:select (substitute-keyword-arguments))
  #:use-module ((guix build utils) #:select (mkdir-p compressor))
  #:use-module ((gcrypt hash) #:hide (sha256))
  #:use-module (guix build-system gnu)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bootstrap)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-64)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 match)
  #:use-module (ice-9 binary-ports)
  #:use-module (web uri)
  #:export (%seed
            random-text
            random-bytevector
            file=?
            canonical-file?
            network-reachable?
            shebang-too-long?
            with-environment-variable

            search-bootstrap-binary

            mock
            dummy-package
            dummy-origin))

;;; Commentary:
;;;
;;; This module provide shared infrastructure for the test suite.  For
;;; internal use only.
;;;
;;; Code:

(define (bootstrap-binary-file program system)
  "Return the absolute file name where bootstrap binary PROGRAM for SYSTEM is
stored."
  (string-append (dirname (search-path %load-path
                                       "gnu/packages/bootstrap.scm"))
                 "/bootstrap/" system "/" program))

(define (search-bootstrap-binary file-name system)
  "Search the bootstrap binary FILE-NAME for SYSTEM.  Raise an error if not
found."
  ;; Note: Keep bootstrap binaries on the local file system so that the 'guix'
  ;; package can provide them as inputs and copy them to the right place.
  (let* ((system (match system
                   ("x86_64-linux" "i686-linux")
                   (_ system)))
         (file   (bootstrap-binary-file file-name system)))
    (if (file-exists? file)
        file
        (error "bootstrap binary not found" file-name system))))

(define (random-seed)
  (or (and=> (getenv "GUIX_TESTS_RANDOM_SEED")
             number->string)
      (logxor (getpid) (car (gettimeofday)))))

(define (%seed)
  (let ((seed (random-seed)))
    (format (current-error-port) "random seed for tests: ~a~%"
            seed)
    (let ((result (seed->random-state seed)))
      (set! %seed (lambda () result))
      result)))

(define (random-text)
  "Return the hexadecimal representation of a random number."
  (number->string (random (expt 2 256) (%seed)) 16))

(define (random-bytevector n)
  "Return a random bytevector of N bytes."
  (let ((bv (make-bytevector n)))
    (let loop ((i 0))
      (if (< i n)
          (begin
            (bytevector-u8-set! bv i (random 256 (%seed)))
            (loop (1+ i)))
          bv))))

(define* (file=? a b #:optional (stat lstat))
  "Return true if files A and B have the same type and same content.  Call
STAT to obtain file metadata."
  (let ((sta (stat a)) (stb (stat b)))
    (and (eq? (stat:type sta) (stat:type stb))
         (case (stat:type sta)
           ((regular)
            (or (and (= (stat:ino sta) (stat:ino stb))
                     (= (stat:dev sta) (stat:dev stb)))
                (equal?
                 (call-with-input-file a get-bytevector-all)
                 (call-with-input-file b get-bytevector-all))))
           ((symlink)
            (string=? (readlink a) (readlink b)))
           (else
            (error "what?" (stat a)))))))

(define (canonical-file? file)
  "Return #t if FILE is in the store, is read-only, and its mtime is 1."
  (let ((st (lstat file)))
    (or (not (string-prefix? (%store-prefix) file))
        (eq? 'symlink (stat:type st))
        (and (= 1 (stat:mtime st))
             (zero? (logand #o222 (stat:mode st)))))))

(define (network-reachable?)
  "Return true if we can reach the Internet."
  (false-if-exception (getaddrinfo "www.gnu.org" "80" AI_NUMERICSERV)))

(define-syntax-rule (mock (module proc replacement) body ...)
  "Within BODY, replace the definition of PROC from MODULE with the definition
given by REPLACEMENT."
  (let* ((m (resolve-module 'module))
         (original (module-ref m 'proc)))
    (dynamic-wind
      (lambda () (module-set! m 'proc replacement))
      (lambda () body ...)
      (lambda () (module-set! m 'proc original)))))

(define-syntax-rule (with-environment-variable variable value body ...)
  "Run BODY with VARIABLE set to VALUE."
  (let ((orig (getenv variable)))
    (dynamic-wind
      (lambda ()
        (setenv variable value))
      (lambda ()
        body ...)
      (lambda ()
        (if orig
            (setenv variable orig)
            (unsetenv variable))))))


;;;
;;; Narinfo files, as used by the substituter.
;;;

(define (shebang-too-long?)
  "Return true if the typical shebang in the current store would exceed
Linux's static limit---the BINPRM_BUF_SIZE constant, normally 128 characters
all included."
  (define shebang
    (string-append "#!" (%store-prefix) "/"
                   (make-string 32 #\a)
                   "-bootstrap-binaries-0/bin/bash\0"))

  (> (string-length shebang) 128))

(define-syntax-rule (dummy-package name* extra-fields ...)
  "Return a \"dummy\" package called NAME*, with all its compulsory fields
initialized with default values, and with EXTRA-FIELDS set as specified."
  (let ((p (package
             (name name*) (version "0") (source #f)
             (build-system gnu-build-system)
             (synopsis #f) (description #f)
             (home-page #f) (license #f))))
    (package (inherit p) extra-fields ...)))

(define-syntax-rule (dummy-origin extra-fields ...)
  "Return a \"dummy\" origin, with all its compulsory fields initialized with
default values, and with EXTRA-FIELDS set as specified."
  (let ((o (origin (method #f) (uri "http://www.example.com")
                   (sha256 (base32 (make-string 52 #\x))))))
    (origin (inherit o) extra-fields ...)))

;;;
;; Local Variables:
;; End:

;;; tests.scm ends here
