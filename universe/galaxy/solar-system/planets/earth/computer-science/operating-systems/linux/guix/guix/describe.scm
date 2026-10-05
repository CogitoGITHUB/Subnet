;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2018-2021, 2024-2025 Ludovic Courtès <ludo@gnu.org>
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

(define-module (guix describe)
  #:use-module (guix memoization)
  #:use-module (guix profiles)
  #:use-module (guix packages)
  #:use-module ((guix utils) #:select (location-file))
  #:use-module ((guix store) #:select (%store-prefix store-path?))
  #:use-module ((guix config) #:select (%state-directory))
  #:autoload   (guix discovery) (all-modules)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-71)
  #:use-module (ice-9 match)
  #:export (current-profile
            current-profile-date
            current-profile-entries
            modules-from-current-profile))

;;; Commentary:
;;;
;;; This module provides supporting code to allow a Guix instance to find, at
;;; run time, which profile it's in.  That allows it to read
;;; meta-information about itself.  It's a bit like ELPA's pkg-info.el.
;;;
;;; Code:

(define initial-program-arguments
  ;; Save the initial program arguments.  This allows us to see the "real"
  ;; 'guix' program, even if 'guix repl -s' calls 'set-program-arguments'
  ;; later on.
  (program-arguments))

(define (find-profile program)
  "Return the profile created by 'guix pull' or 'guix time-machine' that
PROGRAM lives in; PROGRAM is expected to end in \"/bin/guix\".  Return #f if
such a profile could not be found."
  (and (string-suffix? "/bin/guix" program)
       ;; Note: We want to do _lexical dot-dot resolution_.  Using ".."  for
       ;; real would instead take us into the /gnu/store directory that
       ;; ~/.config/guix/current/bin points to, whereas we want to obtain
       ;; ~/.config/guix/current.
       (let ((candidate (dirname (dirname program))))
         (and (file-exists? (string-append candidate "/manifest"))
              (let ((manifest (guard (c ((profile-error? c) #f))
                                (profile-manifest candidate))))
                (define (fallback)
                  (or (and=> (false-if-exception (readlink program))
                             find-profile)
                      (and=> (false-if-exception (readlink (dirname program)))
                             (lambda (target)
                               (find-profile (in-vicinity target "guix"))))))

                ;; Is CANDIDATE the "right" profile--the one created by 'guix
                ;; pull'?  It might be that CANDIDATE itself contains a
                ;; symlink to the "right" profile; this happens for instance
                ;; when using 'guix shell -CW'.  Thus, if CANDIDATE doesn't
                ;; fit the bill, dereference PROGRAM or its parent directory
                ;; and try again.
                (match (and manifest
                            (manifest-lookup manifest
                                             (manifest-pattern (name "guix"))))
                  (#f
                   (fallback))
                  (entry
                   (if (assq 'source (manifest-entry-properties entry))
                       candidate
                       (fallback)))))))))

(define current-profile
  (mlambda ()
    "Return the profile (created by 'guix pull') the calling process lives in,
or #f if this is not applicable."
    (match initial-program-arguments
      ((program . _)
       (find-profile program)))))

(define* (modules-from-current-profile sub-directory
                                       #:key (warn (const #f)))
  "Return the list of modules from SUB-DIRECTORY found in (current-profile).
If 'current-profile' returns #f, search for those modules in each entry of
'%load-path'."
  (all-modules (map (lambda (entry)
                      `(,entry . ,sub-directory))
                    (match (current-profile-entries)
                      (()
                       %load-path)
                      (lst
                       ;; Browse modules from the profile, and nothing else.
                       (map (lambda (entry)
                              (string-append (manifest-entry-item entry)
                                             "/share/guile/site/"
                                             (effective-version)))
                            lst))))
               #:warn warn))

(define (current-profile-date)
  "Return the creation date of the current profile (produced by 'guix pull'),
as a number of seconds since the Epoch, or #f if it could not be determined."
  ;; Normally 'current-profile' will return ~/.config/guix/current.  We need
  ;; to 'readlink' once to get '/var/guix/…/guix-profile', whose mtime is the
  ;; piece of information we're looking for.
  (let loop ((profile (current-profile)))
    (match profile
      (#f #f)
      ((? store-path?) #f)
      (file
       (if (string-prefix? %state-directory file)
           (and=> (lstat file) stat:mtime)
           (catch 'system-error
             (lambda ()
               (let ((target (readlink file)))
                 (loop (if (string-prefix? "/" target)
                           target
                           (string-append (dirname file) "/" target)))))
             (const #f)))))))


(define current-profile-entries
  (mlambda ()
    "Return the list of entries in the 'guix pull' profile the calling process
lives in, or the empty list if this is not applicable."
    (match (current-profile)
      (#f '())
      (profile
       (let ((manifest (profile-manifest profile)))
         (manifest-entries manifest))))))









