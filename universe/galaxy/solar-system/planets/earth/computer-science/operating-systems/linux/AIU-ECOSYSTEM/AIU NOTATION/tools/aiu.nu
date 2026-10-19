#!/usr/bin/env nu
# tools/aiu.nu — the daily script: check, render and roundtrip a .aiu page.
# Registered in plan/package-tree.org (tools/aiu.nu).
#
# One job: give a person ONE command that answers the three questions they
# ask about a page: is it sound, what does it look like, and does it come
# back byte for byte. The Rust binary does the reading. The Racket CLI does
# the diagnosis. This script finds the binary (building it once if it is
# missing), finds Racket, and runs the one command that was asked for.
#
# Who calls it: a person, from the project directory, with the path of a
# .aiu file. Nothing here writes inside the project: the binary is built into
# /tmp and the parse-tree document it produces is written to /tmp.
#
# The commands:
#   nu tools/aiu.nu check <file.aiu>      the diagnosis, non-zero exit if broken
#   nu tools/aiu.nu render <file.aiu>     the plain render on stdout
#   nu tools/aiu.nu roundtrip <file.aiu>  says whether the bytes come back
#   nu tools/aiu.nu json <file.aiu>       the same page as JSON, for a pipe
#   nu tools/aiu.nu from-json <file.json> a JSON file written back as a page

# The project root is the parent of the directory this script lives in, so the
# script works from any working directory.
const project_root = (path self | path dirname | path dirname)

# The Rust binary is built here, never inside the project, so no build
# artefact is ever tracked.
def target-dir [] {
  "/tmp/notation-target"
}

# The path of the built binary inside the target directory.
def binary-path [] {
  ($"(target-dir)/debug/notation" | path expand)
}

# Racket is found through HOME, the one seam the whole project uses.
def racket-path [] {
  ($env.HOME | path join "opt/racket-full/bin/racket" | path expand)
}

# The manifest of the Rust crate, relative to the project root.
def manifest-path [] {
  ($"$project_root/notation/Cargo.toml" | path expand)
}

# The lock file cargo leaves behind. It is not part of the project, so it
# goes away with the build that made it.
def lock-path [] {
  ($"$project_root/notation/Cargo.lock" | path expand)
}

# ensure-binary builds the Rust binary when it is not there yet. The build
# output is shown only when it fails, because a person asking for a render
# does not want a compiler log in the way.
def ensure-binary [] {
  if not (binary-path | path exists) {
    print $"building the Rust binary into (target-dir) ..."
    let built = (^cargo build --manifest-path (manifest-path) --target-dir (target-dir) | complete)
    if (lock-path | path exists) {
      rm (lock-path)
    }
    if $built.exit_code != 0 {
      print $built.stderr
      error make { msg: "the Rust build failed; there is no binary to run" }
    }
  }
}

# The parse-tree document of a page, written to /tmp. The Racket CLI reads a
# document, not a page, so this is the bridge between the two halves.
def parse-document [file: string] {
  let out_file = "/tmp/notation-aiu-document.txt"
  let parsed = (^$"(binary-path)" parse $file | complete)
  if $parsed.exit_code != 0 {
    print $parsed.stderr
    error make { msg: $"the parse of ($file) failed" }
  }
  $parsed.stdout | save --force $out_file
  $out_file
}

# check runs the Racket diagnosis on the parse-tree document. The Racket CLI
# path is RELATIVE on purpose: the absolute project path holds a space and
# racket splits its argument on it.
def do-check [file: string] {
  let document = (parse-document $file)
  cd $project_root
  let result = (^$"(racket-path)" notation/src/entry/cli.rkt check $document | complete)
  print $result.stdout
  if ($result.stderr | str trim) != "" {
    print $result.stderr
  }
  $result.exit_code
}

# do-render prints the plain render: the content without the marks.
def do-render [file: string] {
  let result = (^$"(binary-path)" render $file | complete)
  print $result.stdout
  if ($result.stderr | str trim) != "" {
    print $result.stderr
  }
  $result.exit_code
}

# do-roundtrip says whether the tree prints back to the identical bytes.
def do-roundtrip [file: string] {
  let result = (^$"(binary-path)" roundtrip $file | complete)
  print $result.stdout
  if ($result.stderr | str trim) != "" {
    print $result.stderr
  }
  $result.exit_code
}

# do-json prints the page as JSON. The Racket side needs the Rust binary to
# read the page, so the path of the binary is handed over in the environment.
# That is the one place the two halves meet.
def do-json [file: string] {
  cd $project_root
  with-env {AIU_NOTATION_BIN: (binary-path)} {
    let result = (^$"(racket-path)" notation/src/entry/cli.rkt json $file | complete)
    print $result.stdout
    if ($result.stderr | str trim) != "" {
      print $result.stderr
    }
    $result.exit_code
  }
}

# do-from-json writes a JSON file back as a .aiu page, so a machine-readable
# file can come back to a person who reads notation.
def do-from-json [file: string] {
  cd $project_root
  with-env {AIU_NOTATION_BIN: (binary-path)} {
    let result = (^$"(racket-path)" notation/src/entry/cli.rkt from-json $file | complete)
    print $result.stdout
    if ($result.stderr | str trim) != "" {
      print $result.stderr
    }
    $result.exit_code
  }
}

# main is the entry point: the command, then the path of the .aiu page.
def main [
  command: string
  file: string
] {
  if not ($file | path exists) {
    print $"aiu: no file at ($file)"
    exit 2
  }
  ensure-binary
  # The exit code is worked out first and the script leaves once, because a
  # match arm that calls exit is folded while the file is being read.
  let code = (if $command == "check" {
    do-check $file
  } else if $command == "render" {
    do-render $file
  } else if $command == "roundtrip" {
    do-roundtrip $file
  } else if $command == "json" {
    do-json $file
  } else if $command == "from-json" {
    do-from-json $file
  } else {
    print $"aiu: no command named ($command)"
    print "usage: nu tools/aiu.nu <check|render|roundtrip|json|from-json> <file.aiu>"
    2
  })
  exit $code
}
