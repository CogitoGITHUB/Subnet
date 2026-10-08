(spec
  (format-version 2)
  (name lua)
  (version "5.5.1")
  (summary "Lightweight embeddable scripting language")
  (source (git "https://github.com/lua/lua.git"
               "7579fc9d7ed90240487251dfb69168f8e64e9294"))
  (build (steps (make #:dir "." #:file "makefile" #:targets ("all"))))
  (install (prefix
    (bin "lua" "bin/lua")
    (lib "liblua.a" "lib/liblua.a")
    (include "lua.h" "include/lua.h")
    (include "luaconf.h" "include/luaconf.h")
    (include "lualib.h" "include/lualib.h")
    (include "lauxlib.h" "include/lauxlib.h")
    (check "bin/lua" "-e" "assert(_VERSION)")))
  (license mit)
  (homepage "https://www.lua.org"))
