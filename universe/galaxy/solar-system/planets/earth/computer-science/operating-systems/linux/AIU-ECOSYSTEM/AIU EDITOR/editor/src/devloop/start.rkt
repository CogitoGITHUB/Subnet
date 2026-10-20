#lang racket/base
;; One job: the measured start — how long the program took to start, and
;; where the config came from. Registered in plan/package-tree.org; lands
;; with TODO item 8.
;;
;; The number is measured from the moment the program began to the moment
;; it answers for the first time, and it is printed with that answer. It
;; is INFORMATION, not a gate: nothing waits for it and nothing fails
;; because of it (rule 02).
;;
;; The mode is the owner's choice and it is read once, at the start: there
;; is no watcher, no poll and no timer. The work mode loads the config
;; live from the source tree, so an edit to the source is seen at the
;; next start. The baked mode runs on the defaults the bake made.

(require racket/file
         racket/list
         racket/string
         "../machine/directories.rkt"
         "../narration/print-console.rkt")

;; started-at is the moment the program began, taken once when this
;; module is loaded.
(define started-at (current-inexact-milliseconds))

;; start-ms answers how many milliseconds the program took to start.
(define (start-ms)
  (inexact->exact (round (- (current-inexact-milliseconds) started-at))))

;; mode answers the mode the program is in: "work" or "baked". The
;; environment says which: AIU_EDITOR_MODE=baked is the baked mode, and
;; anything else is the work mode.
(define (mode)
  (let ([asked (getenv "AIU_EDITOR_MODE")])
    (if (and asked (string=? asked "baked")) "baked" "work")))

;; baked-file is where the baked defaults live: the config the bake made
;; into first-class defaults.
(define baked-file
  (build-path (state-dir) "baked" "keymaps.rkt"))

;; baked-tables answers the tables the bake made, or nothing when there
;; is no bake yet. The bake writes a module, and the program loads that
;; module: the defaults are in the program, not in a user config.
(define (baked-tables)
  (and (file-exists? baked-file)
       (with-handlers ([exn:fail? (lambda (why) #f)])
         (dynamic-require (make-resolved-module-path baked-file) 'baked-tables))))

;; config-source answers where the config came from in this mode: the
;; source tree in the work mode, and the baked defaults in the baked one.
(define (config-source)
  (if (string=? (mode) "baked")
      (path->string baked-file)
      "the source tree"))

;; print-start prints the measured start and where the config came from,
;; in the one voice the program has.
(define (print-start)
  (print-line (format "started in ~a ms, ~a mode, the config from ~a"
                       (start-ms)
                       (mode)
                       (config-source))))

;; The measured start and the mode, for the entry above them.
(provide started-at
         start-ms
         mode
         baked-file
         baked-tables
         config-source
         print-start)
