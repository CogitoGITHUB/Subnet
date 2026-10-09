#!/usr/bin/env nu
# scripts/tree.nu -- NodeShape tree, checklist item 0.3.
#
# Prints the tree under the root, hiding every directory named compiled and
# the .git entry. Root defaults to the NodeShape/ directory this script
# lives in, derived the same way scripts/check.nu does it.
# Nu only, no sleeps, no polling.
# Monotonic duration comes from timeit; if timeit is unavailable this fails
# loudly rather than printing a fake number.

def now-utc [] {
  date now | format date "%Y-%m-%dT%H:%M:%SZ"
}

def hidden [name: string] {
  $name == "compiled" or $name == ".git"
}

def walk [dir: path, depth: int, acc: list] {
  if $depth > 32 {
    return $acc
  }
  let indent = (0..<$depth | each { |_| "  " } | str join)
  let entries = (
    ls $dir
    | where { |e| not (hidden ($e.name | path basename)) }
    | sort-by name
  )
  mut lines = $acc
  for e in $entries {
    let name = ($e.name | path basename)
    let marker = (if ($e.type == "dir") { "/" } else { "" })
    $lines = ($lines | append $"($indent)($name)($marker)")
    if ($e.type == "dir") {
      $lines = (walk $e.name ($depth + 1) $lines)
    }
  }
  return $lines
}

def main [--root: path] {
  let root = if $root == null { $env.FILE_PWD | path dirname } else { $root }
  print $"start gate=tree.nu utc=(now-utc) root=($root)"

  let base = ($root | path expand)
  let timed = timeit --output { walk $base 1 [] }

  print $"($base)/"
  for line in $timed.output {
    print $line
  }

  print $"end gate=tree.nu utc=(now-utc) monotonic=($timed.time) hidden=compiled,.git"
}
