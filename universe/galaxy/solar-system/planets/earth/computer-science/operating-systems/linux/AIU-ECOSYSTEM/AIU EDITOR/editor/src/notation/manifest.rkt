#lang racket/base
;; One job: the plugin manifest — what the editor knows about one
;; plugin: its name, its version, the PM package it came from, the
;; spec pm installs it from, the command that starts it, and the calls
;; it provides.
;;
;; The manifest is the EDITOR's shape, not pm's: pm owns the package,
;; the editor owns how it talks to it. A manifest that misses a field
;; is refused, and the field that is missing is named.
;;
;; Registered in plan/package-tree.org; lands with TODO item 17.

(require json
         racket/file
         racket/list
         racket/path
         racket/string
         "../machine/directories.rkt")

;; plugin-dir is where the manifests live: in the state directory,
;; because they must survive a crash.
(define plugin-dir
  (build-path (state-dir) "plugins"))

;; manifest-fields are the fields every manifest must hold.
(define manifest-fields
  '(name version package spec command provides))

;; manifest-path answers where the manifest of one plugin is.
(define (manifest-path name)
  (build-path plugin-dir (string-append name ".json")))

;; read-manifest answers the manifest of one plugin, or nothing when
;; there is none or when it cannot be read.
(define (read-manifest name)
  (with-handlers ([exn:fail? (lambda (why) #f)])
    (define path (manifest-path name))
    (if (file-exists? path)
        (read-json (open-input-file path))
        #f)))

;; read-manifest-file answers the manifest in a file the owner wrote.
(define (read-manifest-file path)
  (with-handlers ([exn:fail? (lambda (why) #f)])
    (read-json (open-input-file path))))

;; write-manifest writes a manifest down and answers it.
(define (write-manifest manifest)
  (ensure-dir plugin-dir)
  (define path (manifest-path (hash-ref manifest 'name "unnamed")))
  (call-with-output-file path
    (lambda (port)
      (write-json manifest port)
      (newline port))
    #:exists 'truncate)
  manifest)

;; manifest-field-ok? answers whether one field of a manifest is there
;; and is of the right kind.
(define (manifest-field-ok? manifest field)
  (define value (hash-ref manifest field #f))
  (cond
    [(not value) #f]
    [(or (eq? field 'command) (eq? field 'provides)) (list? value)]
    [(eq? field 'name) (string? value)]
    [(eq? field 'version) (string? value)]
    [(eq? field 'package) (string? value)]
    [(eq? field 'spec) (string? value)]
    [else #t]))

;; manifest-missing answers the fields a manifest misses: nothing when
;; the manifest is whole.
(define (manifest-missing manifest)
  (if (not manifest)
      manifest-fields
      (filter (lambda (field) (not (manifest-field-ok? manifest field)))
              manifest-fields)))

;; plugin-names answers the plugins the editor knows: the manifests in
;; its own directory, by name.
(define (plugin-names)
  (if (directory-exists? plugin-dir)
      (sort (map plugin-name-of
                  (filter (lambda (path) (string-suffix? (path->string path) ".json"))
                          (directory-list plugin-dir)))
            string<?)
      '()))

;; plugin-name-of answers the name of a plugin by its manifest's file
;; name: the name without the ".json" in front of it.
(define (plugin-name-of path)
  (define name (path->string (file-name-from-path path)))
  (if (string-suffix? name ".json")
      (substring name 0 (- (string-length name) 5))
      name))

;; The manifest, for the areas above it.
(provide plugin-dir
         manifest-fields
         manifest-path
         read-manifest
         read-manifest-file
         write-manifest
         manifest-missing
         plugin-names)
