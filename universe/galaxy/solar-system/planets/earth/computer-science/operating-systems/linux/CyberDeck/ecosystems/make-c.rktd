(ecosystem
  (name make-c)
  (tools ("make" "cc"))
  (build (steps (make #:dir "." #:file "makefile" #:targets ("all")))))
