#lang racket/base
;; One job: the terminal — the raw mode, the settings that were found,
;; and the bytes that arrive. Registered in plan/package-tree.org; lands
;; with TODO item 6.
;;
;; The terminal is put in raw mode so the keys arrive one at a time and
;; nothing waits for a return. The settings that were found are saved
;; FIRST and put back at the end, so the terminal is given back exactly
;; as it was found. A run that was killed leaves the settings on disk,
;; and the next run gives the terminal back before it goes raw again.
;;
;; There is NO timer here. A wait ends on an action: the read waits for
;; the next byte and the reader decides when a key is whole. The kitty
;; keyboard protocol's flags are what tell a key apart — the terminal is
;; asked to report the escape codes it would otherwise swallow.
;;
;; The stty program is the one on this phone, and it is named by its
;; whole path so the program never depends on the PATH.

(require racket/file
         racket/string
         racket/system
         "directories.rkt")

;; stty is the program that reads and writes the settings of the
;; terminal.
(define stty "/usr/bin/stty")

;; settings-file is where the settings of the terminal are kept, so a run
;; that was killed can give the terminal back at the next run.
(define settings-file
  (build-path (state-dir) "terminal-settings"))

;; saved-settings answers the settings that were saved, or nothing when
;; none were saved yet.
(define (saved-settings)
  (if (file-exists? settings-file)
      (let ([text (file->string settings-file)])
        (string-trim text))
      #f))

;; current-settings answers the settings of the terminal as they are now.
;; The settings are one line of text, and the terminal says them itself.
(define (current-settings)
  (let* ([out (open-output-string)]
         [in (open-input-string "")])
    (parameterize ([current-output-port out])
      (system* stty "-g"))
    (string-trim (get-output-string out))))

;; save-settings writes the settings of the terminal to the settings
;; file, so they can be put back later.
(define (save-settings)
  (ensure-dir (state-dir))
  (call-with-output-file settings-file
    (lambda (port) (display (current-settings) port))
    #:exists 'truncate)
  (saved-settings))

;; restore-settings gives the terminal back the settings that were
;; saved, and forgets them: the terminal is as it was found.
(define (restore-settings)
  (define settings (saved-settings))
  (when settings
    (system* stty settings)
    (delete-file settings-file))
  settings)

;; raw-mode puts the terminal in raw mode: the keys arrive one at a time
;; and nothing waits for a return. It answers the settings it saved, so
;; the caller can put them back.
(define (raw-mode)
  (define settings (save-settings))
  (system* stty "-icanon" "-echo" "min" "1" "time" "0")
  settings)

;; The terminal, for the entry above it.
(provide stty
         settings-file
         saved-settings
         current-settings
         save-settings
         restore-settings
         raw-mode)
