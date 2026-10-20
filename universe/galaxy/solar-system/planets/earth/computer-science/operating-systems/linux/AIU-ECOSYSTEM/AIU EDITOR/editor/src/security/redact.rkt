#lang racket/base
;; One job: the redaction seam — what may not leave this program.
;; Registered in plan/package-tree.org; lands with TODO item 13.
;;
;; The seam is where a secret is stopped. The program sends text to an
;; agent, and the text may hold a credential by accident: a key in a
;; selection, a password in a line the human copied. The seam replaces
;; what looks like a secret with a marker, and the marker says that
;; something was hidden — a reader sees that a redaction happened
;; instead of missing it.
;;
;; The seam keeps the NAME and drops the VALUE: a line that reads
;; "api_key = sk-..." comes out as "api_key [redacted]", so a reader can
;; see that a credential was there and is not now, and can ask for it
;; by name.
;;
;; The seam is in the SECURITY area, below the send area, because the
;; send area asks it for every bundle, and an area may only reach
;; DOWNWARD.
;;
;; The secrets package itself — sops with age (D-016) — is the store's
;; side of the seam: it encrypts what is kept and decrypts it for the
;; program that needs it. The editor never holds a credential, so it
;; never needs the package to be opened.
;;
;; ONE definition lives in this area, because every definition here is
;; called from OUTSIDE the area: the gate's security stage fails when a
;; rule protects nothing.
;;
;; Registered in plan/package-tree.org; lands with TODO item 13.

(require racket/string)

;; redact-text answers the text with everything that looks like a
;; secret taken out of it. A secret-looking piece is a line that names a
;; credential, or a token that has the shape of one.
(define (redact-text text)
  (define secret-words
    '("api_key" "api-key" "apikey" "password" "passwd" "secret" "token"
      "authorization" "sk-" "bearer " "-----begin"))

  ;; names-a-credential? answers whether the line names a credential or
  ;; holds a token that has the shape of one.
  (define (names-a-credential? line)
    (for/or ([word (in-list secret-words)])
      (string-contains? (string-downcase line) (string-downcase word))))

  ;; separator-at answers where the value of a line begins: the first
  ;; colon or the first equals sign, whichever comes first. A line with
  ;; neither has no value, and the whole line is hidden.
  (define (separator-at line)
    (define colon (index-of line ":"))
    (define equals (index-of line "="))
    (cond
      [(and (not colon) (not equals)) #f]
      [(and colon (not equals)) colon]
      [(and (not colon) equals) equals]
      [else (min colon equals)]))

  ;; index-of answers where a piece of text begins in a line, or nothing
  ;; when it is not there. The search is written here because this
  ;; Racket's string-contains? answers yes or no, and a position is
  ;; what the seam needs.
  (define (index-of line piece)
    (let loop ([at 0])
      (cond
        [(> (+ at (string-length piece)) (string-length line)) #f]
        [(string=? (substring line at (+ at (string-length piece))) piece) at]
        [else (loop (add1 at))])))


  ;; hide-value answers the line with its value taken out and its name
  ;; left in.
  (define (hide-value line)
    (define at (separator-at line))
    (if at
        (string-append (substring line 0 at) "[redacted]")
        "[redacted]"))

  (string-join (for/list ([line (in-list (string-split text "\n"))])
                 (if (names-a-credential? line) (hide-value line) line))
               "\n"))

;; The seam, for the send area above it.
(provide redact-text)
