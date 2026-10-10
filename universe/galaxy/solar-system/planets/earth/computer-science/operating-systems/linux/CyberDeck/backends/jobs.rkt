#lang racket/base
;; jobs.rkt -- timer-free job queue, no daemon (docs/VAULT-SPEC.org).
;; Operations are a closed set of structs. Job files are .rktd written
;; with write; the worker RE-VALIDATES every field on load (name regex,
;; git-url, git-id). Job ids come from atomic exclusive create. Liveness
;; is an fcntl lock per job held for the worker's whole life:
;; acquirable means dead means interrupted. job-wait blocks on that lock
;; (lock release is a D-015 event); cancel arrives by FIFO, SIGTERM is
;; the documented fallback. One-shot setsid worker, strictly serial.

(require racket/contract/base
         racket/string
         racket/file
         racket/system
         racket/runtime-path
         "../core/errors.rkt"
         "../core/git-id.rkt"
         "../core/git-url.rkt"
         "../core/spec.rkt"
         "../core/cancel.rkt"
         "vault.rkt"
         "manifest.rkt")

(provide
 (struct-out op-add)
 (struct-out op-fetch)
 (struct-out op-verify)
 (struct-out op-gc)
 (struct-out op-backup-push)
 (struct-out op-restore)
 (struct-out job)
 (struct-out job-cancel-result)
 (contract-out
  ;; path-string job-op -> job, enqueue plus ensure a worker runs
  [job-start (-> path-string? job-op? job?)]
  ;; path-string string -> job, running+lock-free reads interrupted
  [job-status (-> path-string? string? job?)]
  ;; path-string -> (listof job)
  [job-list (-> path-string? (listof job?))]
  ;; path-string string -> job-cancel-result
  [job-cancel (-> path-string? string? job-cancel-result?)]
  ;; path-string string -> job, completion or kind 'cancelled
  [job-wait (->* (path-string? string?) (#:cancel (or/c evt? #f)) job?)]
  ;; path-string -> (listof job), interrupted work made visible
  [queue-resume (-> path-string? (listof job?))]))

;; Closed operation set (structs carry data only; validated on load).
(struct op-add (package url pin fsck-allow) #:transparent)
(struct op-fetch (package url fsck-allow) #:transparent)
(struct op-verify (full) #:transparent)
(struct op-gc () #:transparent)
(struct op-backup-push (package allow-large?) #:transparent)
(struct op-restore (package) #:transparent)

(define (job-op? v)
  (or (op-add? v) (op-fetch? v) (op-verify? v) (op-gc? v)
      (op-backup-push? v) (op-restore? v)))

(struct job (id package op state phase percent bytes started updated
                error)
  #:transparent)
;; state : (or/c 'queued 'running 'done 'failed 'cancelled 'interrupted)

(struct job-cancel-result (id accepted? note) #:transparent)

;; ---------------------------------------------------------------------------
;; Paths (all under <state>/jobs/)

;; path-string -> path
(define (jobs-dir state-dir)
  (build-path (if (path? state-dir)
                  state-dir
                  (string->path state-dir))
              "jobs"))

;; path-string string -> path, the job record file
(define (job-file state-dir id)
  (build-path (jobs-dir state-dir) (string-append id ".rktd")))

;; path-string string -> path, liveness lock held by the worker
(define (job-lock-path state-dir id)
  (build-path (jobs-dir state-dir) (string-append id ".lock")))

;; path-string string -> path, cancel fifo, O_RDWR both ends
(define (job-fifo-path state-dir id)
  (build-path (jobs-dir state-dir) (string-append id ".fifo")))

;; path-string -> path, pending id list
(define (job-queue-path state-dir)
  (build-path (jobs-dir state-dir) "queue.rktd"))

;; path-string -> path, worker election lock
(define (worker-lock-path state-dir)
  (build-path (jobs-dir state-dir) "worker.lock"))

;; ---------------------------------------------------------------------------
;; Validation on load (every field re-checked, hostile files refused)

;; any -> package-name string or raises kind 'config
(define (check-job-package v)
  (unless (and (string? v)
               (package-name? (string->symbol v)))
    (raise-pm-error 'config 'job-load "bad package name"
                    #:fields (list (cons "value" v))))
  v)

;; any -> string, package name or raises kind 'config
(define (check-job-name v)
  (unless (and (string? v) (package-name? (string->symbol v)))
    (raise-pm-error 'config 'job-load "bad package name"
                    #:fields (list (cons "value" v))))
  v)

;; any -> string, git URL or raises kind 'config
(define (check-job-url v)
  (unless (string? v)
    (raise-pm-error 'config 'job-load "url must be a string"
                    #:fields (list (cons "value" v))))
  (with-handlers ([exn:fail:pm?
                   (lambda (bad)
                     (raise-pm-error 'config 'job-load "bad package url"
                                     #:fields (list (cons "value" v))
                                     #:cause bad))])
    (check-git-url v))
  v)

;; any -> (or/c #f string?), pin or raises kind 'config
(define (check-job-pin v)
  (unless (or (not v) (and (string? v) (git-id? v)))
    (raise-pm-error 'config 'job-load "bad pin"
                    #:fields (list (cons "value" v))))
  v)

;; any -> (listof string?), fsck ids or raises kind 'config
(define (check-job-fsck v)
  (unless (and (list? v) (andmap string? v))
    (raise-pm-error 'config 'job-load "bad fsck-allow"
                    #:fields (list (cons "value" v))))
  v)

;; ---------------------------------------------------------------------------
;; Op wire format (datums; every field re-validated on the way in)

;; job-op -> list, plain data for write
(define (op->datum op)
  (cond [(op-add? op)
         (list 'add (op-add-package op) (op-add-url op)
               (op-add-pin op) (op-add-fsck-allow op))]
        [(op-fetch? op)
         (list 'fetch (op-fetch-package op) (op-fetch-url op)
               (op-fetch-fsck-allow op))]
        [(op-verify? op) (list 'verify (op-verify-full op))]
        [(op-gc? op) (list 'gc)]
        [(op-backup-push? op)
         (list 'backup-push (op-backup-push-package op)
               (op-backup-push-allow-large? op))]
        [(op-restore? op) (list 'restore (op-restore-package op))]
        [else (raise-pm-error 'internal 'op->datum "not a job op"
                              #:fields (list (cons "value" op)))]))

;; any -> job-op, validated or kind 'config
(define (datum->op d)
  (unless (and (list? d) (not (null? d)))
    (raise-pm-error 'config 'job-load "bad op datum"
                    #:fields (list (cons "datum" d))))
  (case (car d)
    [(add)
     (unless (= (length d) 5)
       (raise-pm-error 'config 'job-load "bad add op"
                       #:fields (list (cons "datum" d))))
     (op-add (check-job-package (list-ref d 1))
             (check-job-url (list-ref d 2))
             (check-job-pin (list-ref d 3))
             (check-job-fsck (list-ref d 4)))]
    [(fetch)
     (unless (= (length d) 4)
       (raise-pm-error 'config 'job-load "bad fetch op"
                       #:fields (list (cons "datum" d))))
     (op-fetch (check-job-package (list-ref d 1))
               (check-job-url (list-ref d 2))
               (check-job-fsck (list-ref d 3)))]
    [(verify)
     (unless (and (= (length d) 2) (boolean? (list-ref d 1)))
       (raise-pm-error 'config 'job-load "bad verify op"
                       #:fields (list (cons "datum" d))))
     (op-verify (list-ref d 1))]
    [(gc)
     (unless (= (length d) 1)
       (raise-pm-error 'config 'job-load "bad gc op"
                       #:fields (list (cons "datum" d))))
     (op-gc)]
    [(backup-push)
     (unless (and (= (length d) 3) (boolean? (list-ref d 2)))
       (raise-pm-error 'config 'job-load "bad backup-push op"
                       #:fields (list (cons "datum" d))))
     (op-backup-push (check-job-package (list-ref d 1))
                     (list-ref d 2))]
    [(restore)
     (unless (= (length d) 2)
       (raise-pm-error 'config 'job-load "bad restore op"
                       #:fields (list (cons "datum" d))))
     (op-restore (check-job-package (list-ref d 1)))]
    [else (raise-pm-error 'config 'job-load "unknown op"
                          #:fields (list (cons "datum" d)))]))
;; job -> list, the stored record
(define (job->datum j)
  (list 'job (job-id j) (job-package j) (op->datum (job-op j))
        (job-state j) (job-phase j) (job-percent j) (job-bytes j)
        (job-started j) (job-updated j) (job-error j)))

;; any -> job, validated or kind 'config
(define (datum->job d)
  (unless (and (list? d) (= (length d) 11) (eq? (car d) 'job))
    (raise-pm-error 'config 'job-load "bad job datum"
                    #:fields (list (cons "datum" d))))
  (define r (cdr d))
  (unless (and (string? (list-ref r 0)) (string? (list-ref r 1)))
    (raise-pm-error 'config 'job-load "bad job id or package"
                    #:fields (list (cons "datum" d))))
  (check-job-name (list-ref r 1))
  (unless (memq (list-ref r 3) '(queued running done failed cancelled))
    (raise-pm-error 'config 'job-load "bad job state"
                    #:fields (list (cons "datum" d))))
  (job (list-ref r 0) (list-ref r 1) (datum->op (list-ref r 2))
       (list-ref r 3) (list-ref r 4) (list-ref r 5) (list-ref r 6)
       (list-ref r 7) (list-ref r 8) (list-ref r 9)))

;; ---------------------------------------------------------------------------
;; Persistence (atomic writes; queue is a plain id list)

;; path-string -> void, jobs dir exists
(define (ensure-jobs-dir state-dir)
  (define d (jobs-dir state-dir))
  (unless (directory-exists? d)
    (make-directory* d)))

;; path-string string job -> void, tmp+rename record write
(define (job-write state-dir id j)
  (ensure-jobs-dir state-dir)
  (define p (job-file state-dir id))
  (define tmp (string-append (path->string p) ".tmp"))
  (call-with-output-file tmp
    (lambda (out) (writeln (job->datum j) out))
    #:exists 'truncate/replace)
  (rename-file-or-directory tmp p #t))

;; path-string string -> job, validated on load
(define (job-read state-dir id)
  (define p (job-file state-dir id))
  (unless (file-exists? p)
    (raise-pm-error 'config 'job-read "unknown job id"
                    #:fields (list (cons "id" id))))
  (define d
    (with-handlers ([exn:fail:read?
                     (lambda (e)
                       (raise-pm-error 'config 'job-read "cannot read job"
                                       #:fields (list (cons "id" id))
                                       #:cause e))])
      (call-with-input-file p read)))
  (datum->job d))

;; path-string -> (listof string), pending ids in order
(define (queue-read state-dir)
  (define p (job-queue-path state-dir))
  (if (not (file-exists? p))
      '()
      (with-handlers ([exn:fail:read?
                       (lambda (e)
                         (raise-pm-error 'config 'queue-read
                                         "cannot read queue"
                                         #:fields (list (cons "state"
                                                              (if (path? state-dir)
                                                                  (path->string state-dir)
                                                                  state-dir)))
                                         #:cause e))])
        (define d (call-with-input-file p read))
        (unless (and (list? d) (andmap string? d))
          (raise-pm-error 'config 'queue-read "bad queue"
                          #:fields (list (cons "state" "jobs"))))
        d)))

;; path-string (listof string?) -> void, tmp+rename queue write
(define (queue-write state-dir ids)
  (ensure-jobs-dir state-dir)
  (define p (job-queue-path state-dir))
  (define tmp (string-append (path->string p) ".tmp"))
  (call-with-output-file tmp
    (lambda (out) (writeln ids out))
    #:exists 'truncate/replace)
  (rename-file-or-directory tmp p #t))

;; -> string, fresh id from atomic exclusive create (count-bounded)
(define (fresh-job-id state-dir)
  (ensure-jobs-dir state-dir)
  (define base (current-milliseconds))
  (let loop ((n 0))
    (when (> n 1000)
      (raise-pm-error 'internal 'fresh-job-id "id space exhausted"
                      #:fields (list (cons "state" "jobs"))))
    (define id (format "job-~a-~a" base n))
    (define p (job-file state-dir id))
    (define done?
      (with-handlers ([exn:fail:filesystem?
                       (lambda (_) #f)])
        (call-with-output-file p
          (lambda (out) (writeln (list 'job-reserved id) out)))
        #t))
    (if done? id (loop (+ n 1)))))

;; ---------------------------------------------------------------------------
;; Liveness (the lock is the truth; the record is just data)

;; path-string string -> boolean, #t while a worker holds the job
(define (job-live? state-dir id)
  (call-with-file-lock/timeout (job-lock-path state-dir id)
                               'exclusive
                               (lambda () #f)
                               (lambda () #t)
                               #:max-delay 0))

;; path-string string -> job, interrupted derived when lock is free
(define (job-status state-dir id)
  (define j (job-read state-dir id))
  (if (and (eq? (job-state j) 'running)
           (not (job-live? state-dir id)))
      (struct-copy job j [state 'interrupted])
      j))

;; path-string -> (listof string), every job id on disk, sorted
(define (queue-all-ids state-dir)
  (ensure-jobs-dir state-dir)
  (sort (for/list ([p (in-list (directory-list (jobs-dir state-dir)))]
                   #:when (let ((s (path->string p)))
                            (and (string-suffix? s ".rktd")
                                 (not (equal? s "queue.rktd")))))
          (path->string (path-replace-extension p #"")))
        string<?))

;; path-string -> (listof job), every stored record with liveness applied
(define (job-list state-dir)
  (for/list ([id (in-list (queue-all-ids state-dir))])
    (job-status state-dir id)))

;; path-string -> (listof job), interrupted work requeued, done skipped
(define (queue-resume state-dir)
  (ensure-jobs-dir state-dir)
  (define visible
    (for/list ([id (in-list (queue-all-ids state-dir))])
      (define j (job-read state-dir id))
      (cond [(eq? (job-state j) 'done) #f]
            [(and (eq? (job-state j) 'running)
                  (not (job-live? state-dir id)))
             (define back (struct-copy job j [state 'queued]))
             (job-write state-dir id back)
             back]
            [else j])))
  (for/list ([j (in-list visible)] #:when j) j))

;; ---------------------------------------------------------------------------
;; Starting work (enqueue plus elect a worker)

;; path-string -> (or/c path #f), this module for the worker child
(define-runtime-path jobs-module-path ".")

;; job-op -> string, package the op concerns ("" when none)
(define (op-package op)
  (cond [(op-add? op) (op-add-package op)]
        [(op-fetch? op) (op-fetch-package op)]
        [(op-backup-push? op) (op-backup-push-package op)]
        [(op-restore? op) (op-restore-package op)]
        [else ""]))

;; path-string -> boolean, a worker already holds the election lock
(define (worker-running? state-dir)
  (call-with-file-lock/timeout (worker-lock-path state-dir)
                               'exclusive
                               (lambda () #f)
                               (lambda () #t)
                               #:max-delay 0))

;; path-string -> void, one-shot setsid worker when none runs
(define (ensure-worker state-dir)
  (ensure-jobs-dir state-dir)
  (unless (worker-running? state-dir)
    (define setsid-exe
      (or (find-executable-path "setsid")
          (raise-pm-error 'config 'ensure-worker "setsid not found"
                          #:hint "install util-linux so workers detach")))
    (define racket-exe (find-system-path 'exec-file))
    (define mod-path
      (path->string (build-path jobs-module-path "jobs.rkt")))
    (define sdir (if (path? state-dir)
                     (path->string state-dir)
                     state-dir))
    ;; Spawn the module's own main submodule with the state dir as its
    ;; single argument. The previous form used `racket -e "(require
    ;; (file jobs.rkt)) (worker-main DIR)"`, but worker-main is not
    ;; provided, so every worker died at module load with
    ;; "worker-main: undefined" and no job ever ran.
    (define child
      (process* (path->string setsid-exe)
                (path->string racket-exe) mod-path sdir))
    ((list-ref child 4) 'wait)))

;; path-string job-op -> job, rate-limited enqueue plus worker
(define (job-start state-dir job-op)
  (ensure-jobs-dir state-dir)
  (define pending
    (for/list ([id (in-list (queue-all-ids state-dir))]
               #:when (memq (job-state (job-read state-dir id))
                            '(queued running)))
      id))
  (when (>= (length pending) 64)
    (raise-pm-error 'config 'job-start "too many pending jobs"
                    #:fields (list (cons "pending" pending))))
  (define id (fresh-job-id state-dir))
  (define now (current-seconds))
  (define j (job id (op-package job-op) job-op 'queued "" 0 0 now now #f))
  (job-write state-dir id j)
  (queue-write state-dir (append (queue-read state-dir) (list id)))
  (ensure-worker state-dir)
  j)

;; path-string string -> job-cancel-result, FIFO or refusal
(define (job-cancel state-dir id)
  (ensure-jobs-dir state-dir)
  (define j (job-read state-dir id))
  (cond [(not (memq (job-state j) '(queued running)))
         (job-cancel-result id #f "job is not running")]
        [(not (job-live? state-dir id))
         (job-cancel-result id #f "worker is gone")]
        [else
         ;; The fifo may not exist yet (holder has not reached its
         ;; barrier). mkfifo + O_RDWR never blocks: we hold both
         ;; ends, so the write is a signal or a buffered no-op.
         (job-make-fifo state-dir id)
         (define fifo (job-fifo-path state-dir id))
         ;; open-input-output-file yields the read port then the write
         ;; port; only the write end goes to display.
         (define-values (_in out)
           (open-input-output-file fifo #:exists 'update))
         (displayln "cancel" out)
         (flush-output out)
         (close-output-port out)
         (job-cancel-result id #t "cancel requested")]))

;; path-string string -> job, completion or kind 'cancelled.
;; Fast paths first (file done, or worker gone); only a live running
;; job blocks, on the fifo line, which is an event wait (D-015).
(define (job-wait state-dir id #:cancel [cancel #f])
  (define j (job-read state-dir id))
  (cond [(memq (job-state j) '(done failed cancelled)) j]
        [(not (job-live? state-dir id)) (job-status state-dir id)]
        [else
         (define in (open-input-file (job-fifo-path state-dir id)))
         (define r (sync in (or cancel never-evt)))
         (cond [(eq? r in)
                (define line (read-line in))
                (close-input-port in)
                (cond [(equal? line "done")
                       (job-status state-dir id)]
                      [(equal? line "cancel")
                       (raise-pm-error 'cancelled 'job-wait "wait cancelled"
                                       #:fields (list (cons "id" id)))]
                      [else (job-status state-dir id)])]
               [else
                (close-input-port in)
                (raise-pm-error 'cancelled 'job-wait "wait cancelled"
                                #:fields (list (cons "id" id)))])]))

;; ---------------------------------------------------------------------------
;; The worker (one-shot, serial, rechecks the queue once when empty)

;; path-string -> path-string, vault beside the state dir (D-016 layout)
(define (worker-vault-root state-dir)
  (build-path (if (path? state-dir)
                  state-dir
                  (string->path state-dir))
              "vault.git"))

;; path-string -> path-string, manifest beside the state dir
(define (worker-manifest-path state-dir)
  (build-path (if (path? state-dir)
                  state-dir
                  (string->path state-dir))
              "manifest.rktd"))

;; string -> boolean, ssh urls always carry the host-key hint
(define (ssh-like-url? url)
  (or (string-prefix? url "ssh://")
      (regexp-match? #rx"^[^/:@]+@[^/:@]+:" url)))

;; path-string string ... -> void, one status field rewrite
(define (job-progress! state-dir id phase percent bytes)
  (define j (job-read state-dir id))
  (job-write state-dir id
             (struct-copy job j
                          [phase phase]
                          [percent (or percent (job-percent j))]
                          [bytes (or bytes (job-bytes j))]
                          [updated (current-seconds)])))

;; path-string string -> (-> fetch-progress? any/c), status relay
(define (job-progress-sink state-dir id)
  (lambda (p)
    (job-progress! state-dir id
                    (fetch-progress-phase p)
                    (fetch-progress-percent p)
                    (fetch-progress-bytes p))))

;; ---------------------------------------------------------------------------
;; Running one job (worker side; fifo cancel, status relay, manifest)

;; path-string string -> void, fifo exists (external mkfifo)
(define (job-make-fifo state-dir id)
  (define fifo (job-fifo-path state-dir id))
  (unless (file-exists? fifo)
    (define mkfifo-exe
      (or (find-executable-path "mkfifo")
          (raise-pm-error 'config 'worker "mkfifo not found"
                          #:hint "install coreutils for job fifos")))
    (define maker
      (process* (path->string mkfifo-exe) (path->string fifo)))
    (void ((list-ref maker 4) 'wait))))

;; input-port -> void, drop stale lines left by dead runs
(define (fifo-drain! io)
  (let loop ((n 0))
    (when (and (byte-ready? io) (< n 100))
      (read-line io)
      (loop (+ n 1)))))

;; job-op -> (or/c string? #f), url for the ssh hint
(define (op-url op)
  (cond [(op-add? op) (op-add-url op)]
        [(op-fetch? op) (op-fetch-url op)]
        [else #f]))

;; path-string job (-> fetch-progress? any/c) evt? -> void, one op
(define (worker-run-op state-dir j sink cancel-evt)
  (define id (job-id j))
  (define op (job-op j))
  (define vault-root (worker-vault-root state-dir))
  (define holder (format "job ~a" id))
  (cond [(op-add? op)
         (define r (vault-add vault-root (op-add-package op)
                              (op-add-url op)
                              #:pin (op-add-pin op)
                              #:fsck-allow (op-add-fsck-allow op)
                              #:cancel cancel-evt
                              #:on-progress sink
                              #:holder holder))
         (worker-manifest-touch state-dir op)
         (void)]
        [(op-fetch? op)
         (define r (vault-fetch-namespace vault-root
                                          (op-fetch-package op)
                                          (op-fetch-url op)
                                          #:fsck-allow (op-fetch-fsck-allow op)
                                          #:cancel cancel-evt
                                          #:on-progress sink
                                          #:holder holder))
         (worker-manifest-touch state-dir op)
         (void)]
        [(op-verify? op)
         (vault-verify vault-root #:full (op-verify-full op))
         (void)]
        [(op-gc? op)
         (vault-gc vault-root #:cancel cancel-evt
                    #:on-progress sink #:holder holder)
         (void)]
        [else
         (raise-pm-error 'config 'worker-run-op "op not in this stage"
                          #:fields (list (cons "op" (format "~s" op))))]))

;; path-string job-op -> void, inventory upsert after add/fetch
(define (worker-manifest-touch state-dir op)
  (define mfile (worker-manifest-path state-dir))
  (define name
    (cond [(op-add? op) (op-add-package op)]
          [else (op-fetch-package op)]))
  (define url
    (cond [(op-add? op) (op-add-url op)]
          [else (op-fetch-url op)]))
  (define old (manifest-get (manifest-read mfile) name))
  (define now (current-seconds))
  (define allow
    (cond [(op-add? op) (op-add-fsck-allow op)]
          [else (op-fetch-fsck-allow op)]))
  (manifest-write mfile
                  (manifest-upsert
                   (manifest-read mfile)
                   (manifest-entry name url
                                   (string-append "refs/vault/" name)
                                   (if old
                                       (manifest-entry-added old)
                                       now)
                                   now allow))))

;; path-string string -> void, run one queued job to completion
;; path-string string -> void, fifo first so waiters pair up.
;; The fifo opens before the lock: whenever the lock is held, a write
;; end already exists and job-wait never strands on open.
(define (worker-run-one state-dir id)
  (define j (job-read state-dir id))
  (when (eq? (job-state j) 'queued)
    (job-make-fifo state-dir id)
    ;; Read port is the one the waiter blocks on; write port is how
    ;; the holder signals completion.
    (define-values (io _w) (open-input-output-file
                            (job-fifo-path state-dir id) #:exists 'update))
    (fifo-drain! io)
    (call-with-file-lock/timeout (job-lock-path state-dir id)
                                 'exclusive
                                 (lambda () (worker-run-held state-dir id io))
                                 void
                                 #:max-delay 0)
    (close-output-port io)))

;; path-string string input-port -> void, body with the job lock held.
;; The watcher dies before any final line, so "done" can only reach
;; job-wait; a close with no line reads EOF and derives the state.
(define (worker-run-held state-dir id io)
  (job-write state-dir id
             (struct-copy job (job-read state-dir id)
                          [state 'running]
                          [phase "start"]
                          [updated (current-seconds)]))
  (define-values (cancel-evt trigger-cancel!) (make-cancel-source))
  (define watcher
    (thread
     (lambda ()
       (define line (read-line io))
       (when (equal? line "cancel")
         (trigger-cancel!)))))
  (define j (job-read state-dir id))
  (define (finish state phase error outcome)
    (kill-thread watcher)
    (when (equal? outcome 'done)
      (displayln "done" io)
      (flush-output io))
    (when (equal? outcome 'failed)
      (displayln "failed" io)
      (flush-output io))
    (close-output-port io)
    (job-write state-dir id
               (struct-copy job (job-read state-dir id)
                            [state state]
                            [phase phase]
                            [error error]
                            [updated (current-seconds)]))
    (queue-write state-dir
                 (for/list ([q (in-list (queue-read state-dir))]
                            #:unless (equal? q id))
                   q)))
  (with-handlers ([exn:fail:pm?
                   (lambda (e)
                     (if (eq? (exn:fail:pm-kind e) 'cancelled)
                         (finish 'cancelled "cancelled" #f 'cancelled)
                         (finish 'failed "failed"
                                 (worker-error-text (job-op j)
                                                    (exn-message e))
                                 'failed)))]
                  [exn:fail?
                   (lambda (e)
                     (finish 'failed "failed" (exn-message e) 'failed))])
    (worker-run-op state-dir j (job-progress-sink state-dir id) cancel-evt)
    (finish 'done "done" #f 'done)))

;; job-op string -> string, static ssh hint on ssh failures
(define (worker-error-text op message)
  (define url (op-url op))
  (if (and url (ssh-like-url? url))
      (string-append message
                     " (ssh may be waiting at a prompt;"
                     " connect once manually to accept the host key)")
      message))

;; path-string -> void, serial pass over the queue
(define (worker-pass state-dir)
  (for ([id (in-list (queue-read state-dir))])
    (with-handlers ([exn:fail?
                     (lambda (e) (void))])
      (worker-run-one state-dir id))))

;; path-string -> void, one-shot worker entry for the child
(define (worker-main state-dir)
  (ensure-jobs-dir state-dir)
  (call-with-file-lock/timeout (worker-lock-path state-dir)
                               'exclusive
                               (lambda ()
                                 (worker-pass state-dir)
                                 (queue-resume state-dir)
                                 (void))
                               void
                               #:max-delay 0)
  ;; Released above; recheck once so no enqueue is stranded.
  (unless (null? (queue-read state-dir))
    (call-with-file-lock/timeout (worker-lock-path state-dir)
                                 'exclusive
                                 (lambda () (worker-pass state-dir))
                                 void
                                 #:max-delay 0))
  (void))

;; ---------------------------------------------------------------------------
;; ---------------------------------------------------------------------------
;; Entry point for the detached worker (module+ main, D-029 scope untouched)
(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (unless (= (length args) 1)
    (raise-user-error
     'jobs.rkt
     "worker entry point needs exactly one argument: the jobs state dir"
     "got" args))
  (worker-main (car args)))

(module+ test
  (require rackunit
           racket/file
           racket/system
           "../core/errors.rkt"
           "../core/cancel.rkt"
           "vault.rkt")

  (define test-root (make-temporary-directory "pm-jobs~a"))
  (define state-dir (build-path test-root "state"))
  (make-directory state-dir)

  ;; Op round trip through datums, all six kinds.
  (define ops
    (list (op-add "demo" "https://example.org/a.git" #f '())
          (op-fetch "demo" "https://example.org/a.git" '("badDate"))
          (op-verify #t)
          (op-gc)
          (op-backup-push "demo" #f)
          (op-restore "demo")))
  (for ([o (in-list ops)])
    (check-equal? (datum->op (op->datum o)) o))

  ;; Hostile job files are refused with kind 'config.
  (define (config-refused? thunk)
    (define r
      (with-handlers ([exn:fail:pm? (lambda (e) e)])
        (thunk)
        'no-error))
    (and (exn:fail:pm? r) (eq? (exn:fail:pm-kind r) 'config)))
  (check-true (config-refused?
               (lambda ()
                 (datum->job '(job "x" "Bad!" (gc) queued "" 0 0 1 2 #f)))))
  (check-true (config-refused?
               (lambda ()
                 (datum->job '(job "x" "demo"
                                   (add "demo" "ext::sh -c true" #f ())
                                   queued "" 0 0 1 2 #f)))))
  (check-true (config-refused?
               (lambda () (datum->job '(bogus)))))

  ;; Queue round trip plus resume semantics, no processes.
  (define q1 (job "job-1" "demo" (op-gc) 'done "" 0 0 1 2 #f))
  (define q2 (job "job-2" "demo" (op-gc) 'running "" 0 0 3 4 #f))
  (define q3 (job "job-3" "demo" (op-gc) 'queued "" 0 0 5 6 #f))
  (job-write state-dir "job-1" q1)
  (job-write state-dir "job-2" q2)
  (job-write state-dir "job-3" q3)
  (queue-write state-dir '("job-1" "job-2" "job-3"))
  (check-eq? (job-state (job-status state-dir "job-2")) 'interrupted)
  (check-eq? (job-state (job-read state-dir "job-2")) 'running)
  (check-equal? (map job-id (queue-resume state-dir)) '("job-2" "job-3"))
  (check-eq? (job-state (job-read state-dir "job-2")) 'queued)
  (check-eq? (job-state (job-read state-dir "job-1")) 'done)
  (check-false (job-cancel-result-accepted? (job-cancel state-dir "job-1")))

  ;; Cancel on a live holder is accepted; rendezvous by semaphore.
  (define held "job-held")
  (job-write state-dir held
             (job held "demo" (op-gc) 'running "" 0 0 7 8 #f))
  (define acquired (make-semaphore))
  (define release (make-semaphore))
  (define held-failed (box #f))
  (define held-lock
    (thread
     (lambda ()
       (call-with-file-lock/timeout (job-lock-path state-dir held)
                                    'exclusive
                                    (lambda ()
                                      (semaphore-post acquired)
                                      (semaphore-wait release))
                                    (lambda ()
                                      (set-box! held-failed #t)
                                      (semaphore-post acquired))
                                    #:max-delay 0))))
  (semaphore-wait acquired)
  (check-false (unbox held-failed))
  (check-true (job-cancel-result-accepted? (job-cancel state-dir held)))
  (semaphore-post release)
  (thread-wait held-lock)

  ;; Real kill -9 on a lock holder reads interrupted afterwards.
  ;; Barriers are fifo opens and EOF, never sleeps.
  (define mkfifo-exe (find-executable-path "mkfifo"))
  (define racket-exe (find-system-path 'exec-file))
  (define (make-fifo! path)
    (define maker (process* (path->string mkfifo-exe) (path->string path)))
    ((list-ref maker 4) 'wait))
  (define k-up (build-path test-root "k-up.fifo"))
  (define k-block (build-path test-root "k-block.fifo"))
  (define k-die (build-path test-root "k-die.fifo"))
  (make-fifo! k-up)
  (make-fifo! k-block)
  (make-fifo! k-die)
  (define k-id "job-killed")
  (job-write state-dir k-id
             (job k-id "demo" (op-gc) 'running "" 0 0 9 10 #f))
  (define k-holder-path (build-path test-root "k-holder.rkt"))
  (define k-lock-s (path->string (job-lock-path state-dir k-id)))
  (define k-up-s (path->string k-up))
  (define k-block-s (path->string k-block))
  (define k-die-s (path->string k-die))
  (call-with-output-file k-holder-path
    (lambda (port)
      (display "#lang racket/base\n" port)
      (display "(require racket/file)\n" port)
      (display "(call-with-file-lock/timeout\n" port)
      (display (format " ~s 'exclusive\n" k-lock-s) port)
      (display " (lambda ()\n" port)
      ;; open-input-output-file returns TWO ports. Binding it with a
      ;; single define made the holder die on an arity error before it
      ;; opened anything, and the parent then waited forever for "up".
      (display "   (define-values (die-in die-out)\n     " port)
      (display (format "(open-input-output-file ~s #:exists 'update))\n" k-die-s) port)
      (display "   (close-input-port die-in)\n" port)
      (display (format "   (define up-hold (open-output-file ~s #:exists 'update))\n" k-up-s) port)
      (display "   (displayln \"up\" up-hold)\n" port)
      (display "   (flush-output up-hold)\n" port)
      (display (format "   (define in (open-input-file ~s))\n" k-block-s) port)
      (display "   (read-line in)\n" port)
      (display "   (close-input-port in)\n" port)
      (display "   (close-output-port up-hold)\n" port)
      (display "   (close-output-port die-out))\n" port)
      (display " void\n" port)
      (display " #:max-delay 0)\n" port)))
  (define k-holder-err (build-path test-root "k-holder.err"))
  (define k-holder
    (process* "/usr/bin/sh" "-c"
              (format "~a ~a 2> ~a"
                      (path->string racket-exe)
                      (path->string k-holder-path)
                      (path->string k-holder-err))))
  (define k-ctl (list-ref k-holder 4))
  ;; The parent holds NO write end of k-up. Opening one just to unblock
  ;; its own read, then closing it, hands the read end a premature EOF
  ;; before the holder has opened its writer. Without a writer of its
  ;; own, this open blocks until the holder opens one inside the lock,
  ;; which is the event we actually want to wait for (D-015).
  (define k-up-in (open-input-file k-up))
  (define k-up-line (read-line k-up-in))
  (unless (equal? k-up-line "up")
    (define k-err (build-path test-root "k-holder.err"))
    (define k-err-s (if (file-exists? k-err) (file->string k-err) "<none>"))
    (error 'jobs-test
           "holder never reported readiness; line=~s stderr=~s"
           k-up-line k-err-s))
  (check-equal? k-up-line "up")
  (check-eq? (job-state (job-status state-dir k-id)) 'running)
  ;; The read end opens BEFORE the kill. A fifo read blocks until some
  ;; writer appears, so opening first is what turns the holder's death
  ;; into an EOF event instead of a permanent block. The holder opens
  ;; k-die before it writes "up", and "up" is already consumed above,
  ;; so this thread is past its open before the kill can land. No
  ;; timeout and no polling are involved: the only events are the
  ;; holder's open and its death (D-015).
  (define k-died-vec (box #f))
  (define k-watcher
    (thread (lambda ()
              (define in (open-input-file k-die))
              (define v (read in))
              (close-input-port in)
              (set-box! k-died-vec v))))
  (define k-killer
    (process* "/usr/bin/sh" "-c"
              (format "kill -9 ~a" (number->string (list-ref k-holder 2)))))
  ((list-ref k-killer 4) 'wait)
  (thread-wait k-watcher)
  (check-pred eof-object? (unbox k-died-vec))
  (check-eq? (job-state (job-status state-dir k-id)) 'interrupted)
  (close-input-port k-up-in)
  (k-ctl 'wait)

  ;; Progress relay writes status fields (deterministic unit check).
  (define rel-id "job-relay")
  (job-write state-dir rel-id
             (job rel-id "demo" (op-gc) 'running "" 0 0 11 12 #f))
  ((job-progress-sink state-dir rel-id)
   (fetch-progress "receiving" 45 1024))
  (define rel-back (job-read state-dir rel-id))
  (check-equal? (job-phase rel-back) "receiving")
  (check-equal? (job-percent rel-back) 45)
  (check-equal? (job-bytes rel-back) 1024)

  ;; End to end: three rapid enqueues, one worker, all done, none lost.
  (define e2e-vault (build-path state-dir "vault.git"))
  (make-directory e2e-vault)
  (vault-init e2e-vault)
  (define e1 (job-start state-dir (op-gc)))
  (define e2 (job-start state-dir (op-gc)))
  (define e3 (job-start state-dir (op-gc)))
  (check-eq? (job-state (job-wait state-dir (job-id e1))) 'done)
  (check-eq? (job-state (job-wait state-dir (job-id e2))) 'done)
  (check-eq? (job-state (job-wait state-dir (job-id e3))) 'done)
  ;; Deterministic cancel: live lock plus held writer, pre-fired cancel.
  ;; job-wait must raise without touching job state.
  (define cx "job-cancel-x")
  (job-write state-dir cx
             (job cx "demo" (op-gc) 'running "" 0 0 13 14 #f))
  (define cx-fifo (job-fifo-path state-dir cx))
  (make-fifo! cx-fifo)
  (define cx-writer (open-output-file cx-fifo #:exists 'update))
  (define cx-acquired (make-semaphore))
  (define cx-release (make-semaphore))
  (define cx-holder
    (thread
     (lambda ()
       (call-with-file-lock/timeout (job-lock-path state-dir cx)
                                    'exclusive
                                    (lambda ()
                                      (semaphore-post cx-acquired)
                                      (semaphore-wait cx-release))
                                    void
                                    #:max-delay 0))))
  (semaphore-wait cx-acquired)
  (define-values (cancel-evt trigger-cancel!) (make-cancel-source))
  (trigger-cancel!)
  (check-pred cancelled-error?
              (with-handlers ([exn:fail:pm? (lambda (e) e)])
                (job-wait state-dir cx #:cancel cancel-evt)
                'no-error))
  (check-eq? (job-state (job-read state-dir cx)) 'running)
  (close-output-port cx-writer)
  (semaphore-post cx-release)
  (thread-wait cx-holder)

  (delete-directory/files test-root))
