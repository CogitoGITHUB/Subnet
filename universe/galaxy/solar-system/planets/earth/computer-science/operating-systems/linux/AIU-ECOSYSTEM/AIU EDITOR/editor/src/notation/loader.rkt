#lang racket/base
;; One job: loading a plugin — asking pm whether the package is there,
;; starting the plugin, and calling it across the seam.
;;
;; A plugin that is not installed is refused BY NAME. A plugin that
;; fails to load never takes the editor down: the editor runs without
;; it and says so.
;;
;; Registered in plan/package-tree.org; lands with TODO item 17.

(require json
         racket/file
         racket/list
         racket/string
         "../machine/directories.rkt"
         "../machine/run.rkt"
         "manifest.rkt"
         "pm.rkt"
         "seam.rkt")

;; request-file is where the request of a call is written.
(define request-file (build-path (state-dir) "plugin-request.json"))

;; answer-file is where the plugin writes its answer. The two files live
;; in the state directory, because an answer must survive a crash.
(define answer-file (build-path (state-dir) "plugin-answer.json"))

;; plugin-state answers what the editor knows about one plugin: the
;; manifest, the fields the manifest misses, and the package it came
;; from.
(define (plugin-state name)
  (define manifest (read-manifest name))
  (define missing (manifest-missing manifest))
  (hash 'name name
        'registered (and manifest #t)
        'known (and manifest (null? missing))
        'manifest manifest
        'missing missing
        'package (and manifest (hash-ref manifest 'package #f))))

;; plugin-verdict asks pm about the package of a plugin and answers
;; what pm said. When pm cannot be asked, the answer says that, and it
;; never guesses that the package is there.
(define (plugin-verdict state)
  (define manifest (hash-ref state 'manifest #f))
  (define package (and manifest (hash-ref manifest 'package #f)))
  (define vault (and manifest (hash-ref manifest 'vault #f)))
  (define lockfile (and manifest (hash-ref manifest 'lockfile #f)))
  (cond
    [(not package) "the manifest names no package"]
    [(not vault) "the manifest names no vault, so pm cannot be asked"]
    [(not lockfile) "the manifest names no lockfile, so pm cannot be asked"]
    [else
     (define answer (pm-verify vault lockfile package))
     (if (hash-ref answer 'ok #f)
         "pm says the package is there and verified"
         (format "pm says no: ~a" (string-trim (hash-ref answer 'err ""))))]))

;; call-plugin asks one plugin one seam call and answers its answer.
;; The request goes to a file and the answer comes from a file: no
;; session crosses the boundary.
(define (call-plugin name call args)
  (define state (plugin-state name))
  (cond
    [(not (hash-ref state 'registered #f))
     (hash 'ok #f
           'error (format "the plugin ~a is not registered here" name))]
    [(not (hash-ref state 'known #f))
     (hash 'ok #f
           'error (format "the plugin ~a is registered, but its manifest misses ~a"
                           name (missing-text state)))]
    [(not (seam-known? call))
     (hash 'ok #f 'error (format "the call ~a is not one the editor makes" call))]
    [else
     (define manifest (hash-ref state 'manifest #f))
     (seam-request request-file call args)
     (when (file-exists? answer-file) (delete-file answer-file))
     (define words (append (hash-ref manifest 'command '())
                           (list (path->string request-file)
                                 (path->string answer-file))))
     (define result (run-program (string-join (map shell-quote words) " ") 30))
     (define answer (seam-answer answer-file))
     (if (not answer)
         (hash 'ok #f
               'error (format "the plugin ~a did not answer: ~a"
                               name (string-trim (hash-ref result 'err ""))))
         (hash 'ok (hash-ref answer 'ok #f)
               'answer answer
               'code (hash-ref result 'code -1)))]))

;; load-plugin asks a plugin to describe itself, and answers what it
;; provides. A plugin that is not there is refused by name.
(define (load-plugin name)
  (define answer (call-plugin name "describe" (hasheq)))
  (if (hash-ref answer 'ok #f)
      answer
      (hash 'ok #f 'error (hash-ref answer 'error "the plugin did not answer"))))

;; missing-text answers what a plugin's manifest misses, in words.
(define (missing-text state)
  (define missing (hash-ref state 'missing '()))
  (if (null? missing)
      "the manifest is whole"
      (string-join (map symbol->string missing) ", ")))

;; The loader, for the areas above it.
(provide request-file
         answer-file
         plugin-state
         plugin-verdict
         call-plugin
         load-plugin)
