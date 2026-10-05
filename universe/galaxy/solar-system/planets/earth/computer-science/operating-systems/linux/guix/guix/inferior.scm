;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2018-2025 Ludovic Courtès <ludo@gnu.org>
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

(define-module (guix inferior)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-35)
  #:use-module ((guix diagnostics)
                #:select (source-properties->location))
  #:use-module ((guix utils)
                #:select (%current-system
                          call-with-temporary-directory
                          version>? version-prefix?
                          cache-directory))
  #:use-module (guix gexp)
  #:use-module (guix search-paths)
  #:use-module (guix profiles)
  #:autoload   (guix git) (update-cached-checkout commit-id?)
  #:use-module (guix monads)
  #:use-module (guix base32)
  #:use-module (gcrypt hash)
  #:autoload   (guix cache) (maybe-remove-expired-cache-entries
                             file-expiration-time)
  #:autoload   (guix ui) (build-notifier)
  #:autoload   (guix build utils) (mkdir-p)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-71)
  #:autoload   (ice-9 ftw) (scandir)
  #:use-module (ice-9 match)
  #:use-module (ice-9 vlist)
  #:use-module (ice-9 binary-ports)
  #:use-module ((rnrs bytevectors) #:select (string->utf8))
  #:export (inferior?
            open-inferior
            port->inferior
            close-inferior
            inferior-eval
            inferior-object?
            inferior-exception?
            inferior-exception-arguments
            inferior-exception-inferior
            inferior-exception-stack
            inferior-protocol-error?
            inferior-protocol-error-inferior
            read-repl-response

            inferior-packages
            inferior-available-packages
            lookup-inferior-packages

            inferior-package?
            inferior-package-name
            inferior-package-version
            inferior-package-synopsis
            inferior-package-description
            inferior-package-home-page
            inferior-package-location
            inferior-package-inputs
            inferior-package-native-inputs
            inferior-package-propagated-inputs
            inferior-package-transitive-propagated-inputs
            inferior-package-native-search-paths
            inferior-package-transitive-native-search-paths
            inferior-package-search-paths
            inferior-package-replacement

            inferior-package->manifest-entry

))

;;; Commentary:
;;;
;;; This module provides a way to spawn Guix "inferior" processes and to talk
;;; to them.  It allows us, from one instance of Guix, to interact with
;;; another instance of Guix coming from a different commit.
;;;
;;; Code:

;; Inferior Guix process.
(define-record-type <inferior>
  (inferior pid socket close version packages table)
  inferior?
  (pid      inferior-pid)
  (socket   inferior-socket)
  (close    inferior-close-socket)               ;procedure
  (version  inferior-version)                    ;REPL protocol version
  (packages inferior-package-promise)            ;promise of inferior packages
  (table    inferior-package-table))             ;promise of vhash

(define (write-inferior inferior port)
  (match inferior
    (($ <inferior> pid _ _ version)
     (format port "#<inferior ~a ~a ~a>"
             pid version
             (number->string (object-address inferior) 16)))))

(set-record-type-printer! <inferior> write-inferior)

(define (open-bidirectional-pipe command . args)
  "Open a bidirectional pipe to COMMAND invoked with ARGS and return it, as a
regular file port (socket).

This is equivalent to (open-pipe* OPEN_BOTH ...) except that the result is a
regular file port that can be passed to 'select' ('open-pipe*' returns a
custom binary port)."
  ;; Make sure the sockets are close-on-exec; failing to do that, a second
  ;; inferior (for instance) would inherit the underlying file descriptor, and
  ;; thus (close-port PARENT) in the original process would have no effect:
  ;; the REPL process wouldn't get EOF on standard input.
  (match (socketpair AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0)
    ((parent . child)
     (if (defined? 'spawn)
         (let* ((void (open-fdes "/dev/null" O_WRONLY))
                (pid  (catch 'system-error
                        (lambda ()
                          (spawn command (cons command args)
                                 #:input child
                                 #:output child
                                 #:error (if (file-port? (current-error-port))
                                             (current-error-port)
                                             void)))
                        (const #f))))         ;can't exec, for instance ENOENT
           (close-fdes void)
           (close-port child)
           (values parent pid))
         (match (primitive-fork)                  ;Guile < 3.0.9
           (0
            (dynamic-wind
              (lambda ()
                #t)
              (lambda ()
                (close-port parent)
                (close-fdes 0)
                (close-fdes 1)
                (close-fdes 2)
                (dup2 (fileno child) 0)
                (dup2 (fileno child) 1)
                ;; Mimic 'open-pipe*'.
                (if (file-port? (current-error-port))
                    (let ((error-port-fileno
                           (fileno (current-error-port))))
                      (unless (eq? error-port-fileno 2)
                        (dup2 error-port-fileno
                              2)))
                    (dup2 (open-fdes "/dev/null" O_WRONLY)
                          2))
                (apply execlp command command args))
              (lambda ()
                (primitive-_exit 127))))
           (pid
            (close-port child)
            (values parent pid)))))))

(define* (inferior-pipe directory command error-port)
  "Return two values: an input/output pipe on the Guix instance in DIRECTORY
and its PID.  This runs 'DIRECTORY/COMMAND repl' if it exists, or falls back
to some other method if it's an old Guix."
  (let ((pipe pid (with-error-to-port error-port
                    (lambda ()
                      (open-bidirectional-pipe
                       (string-append directory "/" command)
                       "repl" "-t" "machine")))))
    (if (eof-object? (peek-char pipe))
        (begin
          (close-port pipe)

          ;; Older versions of Guix didn't have a 'guix repl' command, so
          ;; emulate it.
          (with-error-to-port error-port
            (lambda ()
              (open-bidirectional-pipe
               "guile"
               "-L" (string-append directory "/share/guile/site/"
                                   (effective-version))
               "-C" (string-append directory "/share/guile/site/"
                                   (effective-version))
               "-C" (string-append directory "/lib/guile/"
                                   (effective-version) "/site-ccache")
               "-c"
               (object->string
                `(begin
                   (primitive-load ,(search-path %load-path
                                                 "guix/repl.scm"))
                   ((@ (guix repl) machine-repl))))))))
        (values pipe pid))))

(define* (port->inferior pipe #:optional (close close-port))
  "Given PIPE, an input/output port, return an inferior that talks over PIPE.
PIPE is closed with CLOSE when 'close-inferior' is called on the returned
inferior."
  (setvbuf pipe 'line)

  (match (read pipe)
    (('repl-version 0 rest ...)
     (letrec ((result (inferior 'pipe pipe close (cons 0 rest)
                                (delay (%inferior-packages result))
                                (delay (%inferior-package-table result)))))

       ;; For protocol (0 1) and later, send the protocol version we support.
       (match rest
         ((n _ ...)
          (when (>= n 1)
            (send-inferior-request '(() repl-version 0 1 1) result)))
         (_
          #t))

       (inferior-eval '(use-modules (guix)) result)
       (inferior-eval '(use-modules (gnu)) result)
       (inferior-eval '(use-modules (ice-9 match)) result)
       (inferior-eval '(use-modules (srfi srfi-34)) result)
       (inferior-eval '(define %package-table (make-hash-table))
                      result)
       result))
    (_
     #f)))

(define* (open-inferior directory
                        #:key (command "bin/guix")
                        (error-port (%make-void-port "w")))
  "Open the inferior Guix in DIRECTORY, running 'DIRECTORY/COMMAND repl' or
equivalent.  Return #f if the inferior could not be launched."
  (let ((pipe pid (inferior-pipe directory command error-port)))
    (port->inferior pipe
                    (lambda (port)
                      (close-port port)
                      (waitpid pid)))))

(define (close-inferior inferior)
  "Close INFERIOR."
  (let ((close (inferior-close-socket inferior)))
    (close (inferior-socket inferior))))

;; Non-self-quoting object of the inferior.
(define-record-type <inferior-object>
  (inferior-object address appearance)
  inferior-object?
  (address     inferior-object-address)
  (appearance  inferior-object-appearance))

(define (write-inferior-object object port)
  (match object
    (($ <inferior-object> _ appearance)
     (format port "#<inferior-object ~a>" appearance))))

(set-record-type-printer! <inferior-object> write-inferior-object)

;; Reified exception thrown by an inferior.
(define-condition-type &inferior-exception &error
  inferior-exception?
  (arguments  inferior-exception-arguments)       ;key + arguments
  (inferior   inferior-exception-inferior)        ;<inferior> | #f
  (stack      inferior-exception-stack))          ;list of (FILE COLUMN LINE)

(define-condition-type &inferior-protocol-error &error
  inferior-protocol-error?
  (inferior  inferior-protocol-error-inferior))   ;<inferior>

(define* (read-repl-response port #:optional inferior)
  "Read a (guix repl) response from PORT and return it as a Scheme object.
Raise '&inferior-exception' when an exception is read from PORT."
  (define sexp->object
    (match-lambda
      (('value value)
       value)
      (('non-self-quoting address string)
       (inferior-object address string))))

  (match (read port)
    (('values objects ...)
     (apply values (map sexp->object objects)))
    (('exception ('arguments key objects ...)
                 ('stack frames ...))
     ;; Protocol (0 1 1) and later.
     (raise (condition (&inferior-exception
                        (arguments (cons key (map sexp->object objects)))
                        (inferior inferior)
                        (stack frames)))))
    (('exception key objects ...)
     ;; Protocol (0 0).
     (raise (condition (&inferior-exception
                        (arguments (cons key (map sexp->object objects)))
                        (inferior inferior)
                        (stack '())))))
    (_
     ;; Protocol error.
     (raise (condition (&inferior-protocol-error
                        (inferior inferior)))))))

(define (read-inferior-response inferior)
  (read-repl-response (inferior-socket inferior)
                      inferior))

(define (send-inferior-request exp inferior)
  (write exp (inferior-socket inferior))
  (newline (inferior-socket inferior)))

(define (inferior-eval exp inferior)
  "Evaluate EXP in INFERIOR."
  (send-inferior-request exp inferior)
  (read-inferior-response inferior))


;;;
;;; Inferior packages.
;;;

(define-record-type <inferior-package>
  (inferior-package inferior name version id)
  inferior-package?
  (inferior   inferior-package-inferior)
  (name       inferior-package-name)
  (version    inferior-package-version)
  (id         inferior-package-id))

(define (write-inferior-package package port)
  (match package
    (($ <inferior-package> _ name version)
     (format port "#<inferior-package ~a@~a ~a>"
             name version
             (number->string (object-address package) 16)))))

(set-record-type-printer! <inferior-package> write-inferior-package)

(define (%inferior-packages inferior)
  "Compute the list of inferior packages from INFERIOR."
  (let ((result (inferior-eval
                 '(fold-packages (lambda (package result)
                                   (let ((id (object-address package)))
                                     (hashv-set! %package-table id package)
                                     (cons (list (package-name package)
                                                 (package-version package)
                                                 id)
                                           result)))
                                 '())
                 inferior)))
    (map (match-lambda
           ((name version id)
            (inferior-package inferior name version id)))
         result)))

(define (inferior-packages inferior)
  "Return the list of packages known to INFERIOR."
  (force (inferior-package-promise inferior)))

(define (%inferior-package-table inferior)
  "Compute a package lookup table for INFERIOR."
  (fold (lambda (package table)
          (vhash-cons (inferior-package-name package) package
                      table))
        vlist-null
        (inferior-packages inferior)))

(define (inferior-available-packages inferior)
  "Return the list of name/version pairs corresponding to the set of packages
available in INFERIOR.

This is faster and less resource-intensive than calling 'inferior-packages'."
  (if (inferior-eval '(defined? 'fold-available-packages)
                     inferior)
      (inferior-eval '(fold-available-packages
                       (lambda* (name version result
                                      #:key supported? deprecated?
                                      #:allow-other-keys)
                         (if (and supported? (not deprecated?))
                             (acons name version result)
                             result))
                       '())
                     inferior)

      ;; As a last resort, if INFERIOR is old and lacks
      ;; 'fold-available-packages', fall back to 'inferior-packages'.
      (map (lambda (package)
             (cons (inferior-package-name package)
                   (inferior-package-version package)))
           (inferior-packages inferior))))

(define* (lookup-inferior-packages inferior name #:optional version)
  "Return the sorted list of inferior packages matching NAME in INFERIOR, with
highest version numbers first.  If VERSION is true, return only packages with
a version number prefixed by VERSION."
  ;; This is the counterpart of 'find-packages-by-name'.
  (sort (filter (lambda (package)
                  (or (not version)
                      (version-prefix? version
                                       (inferior-package-version package))))
                (vhash-fold* cons '() name
                             (force (inferior-package-table inferior))))
        (lambda (p1 p2)
          (version>? (inferior-package-version p1)
                     (inferior-package-version p2)))))

(define (inferior-package-field package getter)
  "Return the field of PACKAGE, an inferior package, accessed with GETTER."
  (let ((inferior (inferior-package-inferior package))
        (id       (inferior-package-id package)))
    (inferior-eval `(,getter (hashv-ref %package-table ,id))
                   inferior)))

(define* (inferior-package-synopsis package #:key (translate? #t))
  "Return the Texinfo synopsis of PACKAGE, an inferior package.  When
TRANSLATE? is true, translate it to the current locale's language."
  (inferior-package-field package
                          (if translate?
                              '(compose (@ (guix ui) P_) package-synopsis)
                              'package-synopsis)))

(define* (inferior-package-description package #:key (translate? #t))
  "Return the Texinfo description of PACKAGE, an inferior package.  When
TRANSLATE? is true, translate it to the current locale's language."
  (inferior-package-field package
                          (if translate?
                              '(compose (@ (guix ui) P_) package-description)
                              'package-description)))

(define (inferior-package-home-page package)
  "Return the home page of PACKAGE."
  (inferior-package-field package 'package-home-page))

(define (inferior-package-location package)
  "Return the source code location of PACKAGE, either #f or a <location>
record."
  (source-properties->location
   (inferior-package-field package
                           '(compose (lambda (loc)
                                       (and loc
                                            (location->source-properties
                                             loc)))
                                     package-location))))

(define (inferior-package-input-field package field)
  "Return the input field FIELD (e.g., 'native-inputs') of PACKAGE, an
inferior package."
  (define field*
    `(compose (lambda (inputs)
                (map (match-lambda
                       ;; XXX: Origins are not handled.
                       ((label (? package? package) rest ...)
                        (let ((id (object-address package)))
                          (hashv-set! %package-table id package)
                          `(,label (package ,id
                                            ,(package-name package)
                                            ,(package-version package))
                                   ,@rest)))
                       (x
                        x))
                     inputs))
              ,field))

  (define inputs
    (inferior-package-field package field*))

  (define inferior
    (inferior-package-inferior package))

  (map (match-lambda
         ((label ('package id name version) . rest)
          ;; XXX: eq?-ness of inferior packages is not preserved here.
          `(,label ,(inferior-package inferior name version id)
                   ,@rest))
         (x x))
       inputs))

(define inferior-package-inputs
  (cut inferior-package-input-field <> 'package-inputs))

(define inferior-package-native-inputs
  (cut inferior-package-input-field <> 'package-native-inputs))

(define inferior-package-propagated-inputs
  (cut inferior-package-input-field <> 'package-propagated-inputs))

(define inferior-package-transitive-propagated-inputs
  (cut inferior-package-input-field <> 'package-transitive-propagated-inputs))

(define (%inferior-package-search-paths package field)
  "Return the list of search path specifications of PACKAGE, an inferior
package."
  (define paths
    (inferior-package-field package
                            `(compose (lambda (paths)
                                        (map (@ (guix search-paths)
                                                search-path-specification->sexp)
                                             paths))
                                      ,field)))

  (map sexp->search-path-specification paths))

(define inferior-package-native-search-paths
  (cut %inferior-package-search-paths <> 'package-native-search-paths))

(define inferior-package-search-paths
  (cut %inferior-package-search-paths <> 'package-search-paths))

(define inferior-package-transitive-native-search-paths
  (cut %inferior-package-search-paths <> 'package-transitive-native-search-paths))

(define (inferior-package-replacement package)
  "Return the replacement for PACKAGE.  This will either be an inferior
package, or #f."
  (match (inferior-package-field
          package
          '(compose (match-lambda
                      ((? package? package)
                       (let ((id (object-address package)))
                         (hashv-set! %package-table id package)
                         (list id
                               (package-name package)
                               (package-version package))))
                      (#f #f))
                    package-replacement))
    (#f #f)
    ((id name version)
     (inferior-package (inferior-package-inferior package)
                       name
                       version
                       id))))


;;; Manifest entries.
;;;

(define* (inferior-package->manifest-entry package
                                           #:optional (output "out")
                                           #:key (properties '()))
  "Return a manifest entry for the OUTPUT of package PACKAGE."
  (define cache
    (make-hash-table))

  (define-syntax-rule (memoized package output exp)
    ;; Memoize the entry returned by EXP for PACKAGE/OUTPUT.  This is
    ;; important as the same package may be traversed many times through
    ;; propagated inputs, and querying the inferior is costly.  Use
    ;; 'hash'/'equal?', which is okay since <inferior-package> is simple.
    (let ((compute (lambda () exp))
          (key     (cons package output)))
      (or (hash-ref cache key)
          (let ((result (compute)))
            (hash-set! cache key result)
            result))))

  (let loop ((package package)
             (output  output)
             (parent  (delay #f)))
    (memoized package output
      ;; For each dependency, keep a promise pointing to its "parent" entry.
      (letrec* ((deps  (map (match-lambda
                              ((label package)
                               (loop package "out" (delay entry)))
                              ((label package output)
                               (loop package output (delay entry))))
                            (inferior-package-propagated-inputs package)))
                (entry (manifest-entry
                         (name (inferior-package-name package))
                         (version (inferior-package-version package))
                         (output output)
                         (item package)
                         (dependencies (delete-duplicates deps))
                         (search-paths
                          (inferior-package-transitive-native-search-paths package))
                         (parent parent)
                         (properties properties))))
        entry))))


;;; Local Variables:
;;; eval: (put 'memoized 'scheme-indent-function 1)
;;; End:
