#lang racket/base
;; One job: the ONE printer to the terminal — every line this program writes
;; goes through here. Registered in plan/package-tree.org; lands with TODO item 1.
;;
;; Nothing else in the program writes to the terminal. That is what makes the
;; log readable: one voice, one place, and one place to look when a line is
;; wrong.

(require racket/list
         racket/string
         "events.rkt"
         "../errors/render.rkt")

;; output-format is the shape the printer writes: sexp by default, json on
;; demand (rule 06).
(define output-format (make-parameter 'sexp))

;; print-line writes one line to the terminal and flushes it, so a line is
;; never left sitting in a buffer when the program ends.
(define (print-line text)
  (displayln text)
  (flush-output (current-output-port)))

;; print-event writes one event as one line, in the requested format.
(define (print-event e)
  (print-line (event->string e (output-format))))

;; print-error writes one error as one line, through this same printer, so a
;; failure and the narration around it read in one voice.
(define (print-error e)
  (print-line (err-line e)))

;; event->string turns one event into one line, in the given format: sexp or
;; json.
(define (event->string e fmt)
  (if (eq? fmt 'json) (event->json e) (event->sexp e)))

;; event->sexp turns one event into a readable s-expression, on one line.
(define (event->sexp e)
  (format "~a" (list (event-kind e) (event-who e) (event-why e)
                     (event-started e) (event-ended e) (event-duration-ms e)
                     (event-data e) (event-redacted e))))

;; event->json turns one event into a JSON object with the fields rule 06
;; names: who, why, the UTC start and end, the duration and the data.
(define (event->json e)
  (object->json (list (cons 'kind (symbol->string (event-kind e)))
                       (cons 'who (event-who e))
                       (cons 'why (event-why e))
                       (cons 'started (event-started e))
                       (cons 'ended (or (event-ended e) ""))
                       (cons 'duration_ms (or (event-duration-ms e) 0))
                       (cons 'data (event-data e))
                       (cons 'redacted (event-redacted e)))))

;; value->json turns a value into JSON text: #f is null, #t is true, a number
;; is a number, a string is quoted, a list of pairs is an object and any other
;; list is an array.
(define (value->json v)
  (cond
    [(eq? v #f) "null"]
    [(eq? v #t) "true"]
    [(string? v) (json-string v)]
    [(number? v) (number->string v)]
    [(and (list? v) (not (null? v)) (andmap pair? v)) (object->json v)]
    [(list? v) (array->json v)]
    [else (json-string (format "~a" v))]))

;; object->json turns a list of pairs into a JSON object.
(define (object->json pairs)
  (define parts
    (map (lambda (p)
           (format "~a:~a" (json-string (symbol->string (car p))) (value->json (cdr p))))
         pairs))
  (format "{~a}" (string-join parts ",")))

;; array->json turns a list of values into a JSON array.
(define (array->json vs)
  (format "[~a]" (string-join (map value->json vs) ",")))

;; json-string quotes a string for JSON, and a quote or a backslash inside it
;; is written twice, so the text survives the round trip.
(define (json-string s)
  (define out (open-output-string))
  (for ([c (in-string s)])
    (cond
      [(char=? c #\") (display "\\\"" out)]
      [(char=? c #\\) (display "\\\\" out)]
      [(char=? c #\newline) (display "\\n" out)]
      [(char=? c #\tab) (display "\\t" out)]
      [(char=? c #\return) (display "\\r" out)]
      [else (write-char c out)]))
  (format "\"~a\"" (get-output-string out)))

;; The one printer, for every area above this one.
(provide output-format
         print-line
         print-event
         print-error
         event->string)
