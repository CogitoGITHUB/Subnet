#!/usr/bin/env nu
# scripts/check.nu -- NodeShape gate, checklist item 0.2.
#
# Fails when a required docs file, or the gate itself, is missing under the
# root. Root defaults to the NodeShape/ directory this script lives in.
# Scans only the root. Nu only, no sleeps, no polling.
# Monotonic duration comes from timeit; if timeit is unavailable this fails
# loudly rather than printing a fake number.

def now-utc [] {
  date now | format date "%Y-%m-%dT%H:%M:%SZ"
}

def check-one [root: path, rel: string] {
  let full = ($root | path join $rel)
  { path: $rel, ok: ($full | path exists) }
}

def run-checks [root: path] {
  [
    docs/AI-RULES.org
    docs/DECISIONS.org
    docs/PLAN.org
    docs/CHECKLIST.org
    scripts/check.nu
  ] | each { |rel| check-one $root $rel }
}

def main [--root: path] {
  let root = if $root == null { $env.FILE_PWD | path dirname } else { $root }
  print $"start gate=check.nu utc=(now-utc) root=($root)"

  let timed = timeit --output { run-checks $root }
  let results = $timed.output

  mut failed = 0
  for r in $results {
    if $r.ok {
      print $"PASS ($r.path)"
    } else {
      $failed = $failed + 1
      print $"FAIL ($r.path)"
    }
  }

  print $"end gate=check.nu utc=(now-utc) monotonic=($timed.time) failed=($failed)"

  if $failed > 0 {
    exit 1
  }
}
