# build-lua.nu -- manual E-12b entry point (NOT in the gate).
# Preflights host tools, then runs tools/build-lua.rkt, which does
# the real vault/export/apply flow for Lua and prints the report.
# Run from CyberDeck/: nu tools/build-lua.nu [--fresh]

def main [--fresh] {
  for t in [make cc sh git racket] {
    if (which $t | is-empty) {
      print $"missing tool: ($t), STOP"
      exit 1
    }
  }
  print "tools ok: make cc sh git racket present"
  if $fresh {
    ^racket tools/build-lua.rkt --fresh docs/examples/lua.rktd
  } else {
    ^racket tools/build-lua.rkt docs/examples/lua.rktd
  }
  if $env.LAST_EXIT_CODE != 0 {
    exit $env.LAST_EXIT_CODE
  }
}
