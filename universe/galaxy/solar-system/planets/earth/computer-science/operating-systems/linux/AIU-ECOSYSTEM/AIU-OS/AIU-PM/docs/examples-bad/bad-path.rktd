(spec
  (format-version 2)
  (name bad-path)
  (version "1.0")
  (summary "negative fixture: install escapes the prefix")
  (source (git "https://example.org/demo.git"
               "9edb3f66fd807b096b48283debdcddccfea34bad"))
  (build (steps (copy "a" "b")))
  (install (prefix (bin "../etc/passwd")))
  (license mit)
  (homepage "https://example.org"))
