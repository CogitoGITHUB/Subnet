(ecosystem
  (name cargo)
  (tools ("cargo"))
  (build (steps (cargo #:dir "." #:args ("build" "--release")))))
