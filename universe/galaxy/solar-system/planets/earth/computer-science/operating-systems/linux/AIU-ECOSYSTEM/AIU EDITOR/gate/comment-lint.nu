#!/usr/bin/env nu
# One job: the comment lint — every file has a header, every definition a
# comment above it. Registered in plan/package-tree.org.
#
# It reads every source file of the package and of the gate, and reports two
# kinds of debt: a file that does not open with a header comment, and a
# top-level definition whose line above is not a comment.
#
# It reads code files only: .rkt, .rs and .nu. The .org files carry their own
# header, the #+TITLE line, and the one-way lint reads the indexes.
#
# Style note, learned the hard way on this phone's Nu: every pipeline sits
# inside the parentheses of its let, a boolean chain never breaks over a line,
# and there is no "else if".

use ./env.nu *

# is_code says whether a path is a source file this stage reads.
def is_code [p] {
    let name = ($p | path basename)
    let markers = [".rkt" ".rs" ".nu"]
    $markers | any {|m| $name | str ends-with $m }
}

# kind_of answers the language of a file from its extension.
def kind_of [p] {
    let name = ($p | path basename)
    if ($name | str ends-with ".rkt") {
        "rkt"
    } else {
        if ($name | str ends-with ".rs") {
            "rs"
        } else {
            "nu"
        }
    }
}

# is_comment says whether a line is a comment in the given language.
def is_comment [line kind] {
    if ($kind == "rkt") {
        $line | str starts-with ";"
    } else {
        if ($kind == "rs") {
            $line | str starts-with "//"
        } else {
            $line | str starts-with "#"
        }
    }
}

# definition_markers answers the words that start a top-level definition in
# the given language.
def definition_markers [kind] {
    if ($kind == "rkt") {
        ["(define " "(define(" "(struct "]
    } else {
        if ($kind == "rs") {
            ["fn " "pub fn " "struct " "pub struct " "enum " "pub enum "]
        } else {
            ["def " "const " "export def " "export const "]
        }
    }
}

# is_definition says whether a line starts a top-level definition in the given
# language. Only column zero counts: a definition inside a body is not a file
# header, and this stage checks the file, not every line of it.
def is_definition [line kind] {
    let markers = (definition_markers $kind)
    $markers | any {|m| $line | str starts-with $m }
}

# header_missing says whether a file does not open with a header comment: the
# first line that is not a language marker has to be a comment.
def header_missing [lines kind] {
    let rest = if ($kind == "rkt") { if ($lines | is-empty) { [] } else { $lines | skip 1 } } else { $lines }
    let cand = ($rest | where {|l| ($l | str trim) != "" })
    if ($cand | is-empty) {
        true
    } else {
        let first = ($cand | first)
        if (is_comment $first $kind) { false } else { true }
    }
}

# missing_definition_comments returns every definition whose line above is not
# a comment, one record per offender.
def missing_definition_comments [lines kind] {
    let hits = ($lines | enumerate | where {|e| ($e.index > 0) and (is_definition $e.item $kind) })
    $hits | each {|e|
        let above = ($lines | get ($e.index - 1))
        if (is_comment $above $kind) { null } else { {line: ($e.index + 1), text: ($e.item | str trim)} }
    } | where {|e| $e != null }
}

# main reads every source file and reports the debt it finds.
def main [] {
    let package_files = (glob $"($package_src)/**/*")
    let gate_files = (glob $"($gate_dir)/*")
    let tools_files = (glob $"($tools_dir)/**/*")
    let found = ($package_files | append $gate_files | append $tools_files)
    let all = ($found | where {|p| ($p | path type) == "file" } | where {|p| is_code $p })

    if ($all | is-empty) {
        print "NOTHING-TO-CHECK comment-lint — no source files exist yet"
        exit 0
    }

    let problems = ($all | each {|p|
        let kind = (kind_of $p)
        let lines = (open --raw $p | lines)
        let header = if (header_missing $lines $kind) { [{path: $p, line: 1, why: "the file does not open with a header comment"}] } else { [] }
        let defs = (missing_definition_comments $lines $kind | each {|d| {path: $p, line: $d.line, why: "the definition has no comment above it"} })
        $header | append $defs
    } | flatten)

    let checked = ($all | length)
    if ($problems | is-empty) {
        print $"OK comment-lint — ($checked) files checked, every file has a header and every definition a comment above"
        exit 0
    }

    for p in $problems {
        let rel = ($p.path | path relative-to $project_root)
        print $"COMMENT — ($rel) line ($p.line): ($p.why)"
    }
    print $"COMMENT — ($problems | length) debts in ($checked) files"
    exit 1
}
