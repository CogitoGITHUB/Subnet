(spec
  (format-version 2)
  (name bad-mode)
  (version "1.0")
  (summary "negative fixture: only 755 and 644 are written")
  (source (git "https://example.org/demo.git"
               "9edb3f66fd807b096b48283debdcddccfea34bad"))
  (build (steps (copy "a" "b")))
  (install (prefix (bin "b") (mode "bin/b" 777)))
  (license mit)
  (homepage "https://example.org"))
