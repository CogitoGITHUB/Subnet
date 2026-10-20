#lang racket/base
;; One job: the context bundle shape — what the editor sends to an agent. The shape is
;; the contract's (../contract/context-bundle-format.org): the selection,
;; the file, the position, the notation address, and the why — the why is
;; mandatory.
;;
;; A bundle carries NO agent-specific key: the adapter translates, and
;; the program never learns which agent answers. A bundle carries NO
;; secret: it passes the redaction seam, and an agent receives pointers
;; and text, never credentials.
;;
;; A document is a header and then references: the paths, the addresses
;; and the selections. An absent part stays absent; empty is not a value.
;;
;; Registered in plan/package-tree.org; lands with TODO item 9.

(require racket/list
         racket/string)

;; bundle is what one send carries: the header, the selection, the file,
;; the position, the notation address and the why. A part that is not
;; there stays #f: empty is not a value.
(struct bundle (header selection file position address why) #:transparent)

;; bundle-header is the header every bundle carries: the boundary
;; version, the program that sends, the project it sends from, and the
;; named target agent. The target is named, never inferred.
(define boundary-version "1")

;; make-bundle answers a bundle. The why is mandatory: a send without a
;; reason is refused, because a send nobody can explain is a send that
;; cannot be audited.
(define (make-bundle program project target selection file position address why)
  (if (string=? (string-trim why) "")
      #f
      (bundle (hash 'boundary boundary-version
                     'program program
                     'project project
                     'target target)
              selection
              file
              position
              address
              why)))

;; bundle-document answers the document of a bundle: the header, then the
;; references — the paths, the addresses and the selections. An absent
;; part is left out, so the document says what is there.
(define (bundle-document bundle)
  (define header (bundle-header bundle))
  (define references
    (filter values
            (list (and (bundle-file bundle)
                        (hash 'path (bundle-file bundle)))
                  (and (bundle-position bundle)
                        (hash 'position (bundle-position bundle)))
                  (and (bundle-address bundle)
                        (hash 'address (bundle-address bundle)))
                  (and (bundle-selection bundle)
                        (hash 'selection (bundle-selection bundle))))))
  (list header (hash 'references references)))

;; bundle-lines answers the document of a bundle as lines of text, one
;; part per line, so a person can read what is about to be sent.
(define (bundle-lines bundle)
  (define document (bundle-document bundle))
  (define header (car document))
  (define references (cdr (hash-ref (cadr document) 'references)))
  (append
   (list (format "boundary: ~a  program: ~a  project: ~a  target: ~a"
                 (hash-ref header 'boundary)
                 (hash-ref header 'program)
                 (hash-ref header 'project)
                 (hash-ref header 'target)))
   (list (format "why: ~a" (bundle-why bundle)))
   (for/list ([reference (in-list references)])
     (string-join
      (for/list ([key (in-list (sort (hash-keys reference) string<?))])
        (format "~a: ~a" key (hash-ref reference key)))
      "  "))))

;; The bundle, for the adapter beside it.
(provide bundle
         bundle?
         bundle-header
         bundle-selection
         bundle-file
         bundle-position
         bundle-address
         bundle-why
         boundary-version
         make-bundle
         bundle-document
         bundle-lines)
