#lang racket/base
;; generation.rkt -- generations as data: their names (profile-NNN),
;; numbers, listing, provenance, and the owner names read off their
;; links, plus build-generation! which writes one generation dir of
;; absolute symlinks and its ledger (G-04). It flips nothing; the
;; profile actions live in profile-flip.rkt.

(require racket/file
         racket/list
         racket/path
         "../errors/error-type.rkt")

(provide
 ;; public generation reads
 profile-generations
 generation-provenance
 current-generation
 ;; internal API for profile-flip.rkt and profile-gc.rkt
 gen-dir-name
 next-gen-number
 build-generation!
 generation-owner-names)

;; exact-integer -> string, profile-001 style, sortable as text
(define (gen-dir-name n)
  (define digits (number->string n))
  (string-append "profile-"
                 (make-string (max 0 (- 3 (string-length digits))) #\0)
                 digits))

;; path -> exact-integer, one past the highest generation number
(define (next-gen-number profile-root)
  (define nums
    (for/list ([g (in-list (profile-generations profile-root))])
      (define p (first g))
      (define m (regexp-match #rx"profile-([0-9]+)$"
                              (path->string (file-name-from-path p))))
      (string->number (second m))))
  (if (null? nums) 1 (+ 1 (apply max nums))))

;; path-string -> (listof path), existing generations oldest first
(define (profile-generations profile-root)
  (if (not (directory-exists? profile-root))
      '()
      (sort (for/list ([p (in-list (directory-list profile-root))]
                       #:when (regexp-match? #rx"^profile-[0-9]+$"
                                             (path->string p)))
              (define gen (build-path profile-root p))
              (list gen (generation-provenance (path->string gen))))
            (lambda (a b) (path<? (first a) (first b))))))

;; path-string -> provenance or #f, never raises: a generation without
;; a provenance file predates provenance, and that is absence, not error
(define (generation-provenance gen)
  (with-handlers ([(lambda (e) #t) (lambda (e) #f)])
    (define datum
      (call-with-input-file (build-path (if (path? gen) gen (string->path gen))
                                        "provenance.rktd")
        read))
    (and (pair? datum)
         (eq? (car datum) 'provenance)
         (pair? (cdr datum))
         (let ([p (cadr datum)])
           (and (list? p)
                (= 4 (length p))
                p)))))

;; (listof entry) path-string -> void, one generation dir of links
(define (build-generation! triples gen)
  (define done (make-hash))
  (with-handlers ([exn:fail:filesystem?
                   (lambda (e)
                     (raise-pm-error 'activate 'profile-activate
                                     "cannot build generation"
                                     #:fields `(("dir" . ,(path->string gen)))
                                     #:cause e))])
    (for ([d (in-list '("bin" "lib" "include" "share" "libexec" "man"))])
      (make-directory* (build-path gen d)))
    (for ([t (in-list triples)])
      (define rel (third t))
      (unless (hash-ref done rel #f)
        (hash-set! done rel #t)
        (define link (build-path gen rel))
        (make-directory* (or (path-only link) gen))
        (make-file-or-directory-link (second t) link)))
    ;; G-04: the generation records the ledger it was built from. One
    ;; file, one triple per owned path, so query-owner answers from the
    ;; record instead of re-walking the tree.
    (call-with-output-file (build-path gen "ledger.rktd")
      (lambda (out)
        (write (cons 'ledger
                     (map (lambda (t)
                            (define d (second t))
                            (list (first t)
                                  (if (path? d) (path->string d) d)
                                  (third t)))
                          triples))
               out))
      #:exists 'truncate/replace)))

;; path-string -> path, where the profile link points today
(define (current-generation profile-root)
  (define link (build-path profile-root "profile"))
  (unless (link-exists? link)
    (raise-pm-error 'config 'profile-remove "no active generation"))
  (resolve-path link))

;; path -> (listof string), package names owning links in a generation.
;; Store-layout targets only; anything else names nothing (dev
;; checkouts are E-19's to name, and the remove guard stays loud).
(define (generation-owner-names gen)
  (define names (make-hash))
  (define (walk dir)
    (for ([p (in-list (directory-list dir))])
      (define full (build-path dir p))
      (cond [(link-exists? full)
             (let* ([target
                     (with-handlers ([exn:fail? (lambda (e) #f)])
                       (path->string (resolve-path full)))]
                    [m (and target
                            (regexp-match #rx"/store/([^/]+)/" target))])
               (when m (hash-set! names (second m) #t)))]
            [(directory-exists? full) (walk full)]
            [else (void)])))
  (walk gen)
  (hash-map names (lambda (k v) k)))
