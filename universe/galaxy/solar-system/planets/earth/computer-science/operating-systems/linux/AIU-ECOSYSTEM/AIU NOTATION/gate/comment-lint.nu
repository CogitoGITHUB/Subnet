#!/usr/bin/env nu
# One job: the comment law, made mechanical — every .rkt, .rs and .nu file under
# notation/ and gate/ starts with a header comment (what it is, why it exists,
# who calls it), and every top-level definition has a comment line directly above
# it. Registered in plan/package-tree.org; called by gate/check.nu as stage
# "comment-lint".
#
# It only reads: it never rewrites a file and never loads one, and it names no
# file specially, so the count cannot be made to go down from inside here. Every
# violation is printed as file:line: reason, one per line, and the exit is
# non-zero when at least one exists.
#
# A stage with nothing to check prints NOTHING-TO-CHECK and never PASS (rule 1
# of gate/check.nu). This stage checks the gate's own files, so it always has
# something to check and never prints that.
#
# Style note, kept from the sibling lints: no bare parenthesis inside an
# interpolation string, and every count is bound to a name before it is used.

use ./env.nu *

# comment-marker is the prefix a comment line carries in each language: `;` in
# Racket, `//` in Rust, `#` in Nushell.
def comment-marker [lang: string] {
    if $lang == "rs" { "//" } else if $lang == "rkt" { ";" } else { "#" }
}

# is-comment-line says whether one line, trimmed, is a comment of the file's
# language. A blank line is not a comment.
def is-comment-line [line: string, lang: string] {
    let t = ($line | str trim)
    let marker = (comment-marker $lang)
    if ($t | is-empty) { false } else { ($t | str starts-with $marker) }
}

# header-ok says whether the file starts with a header comment. A shebang and a
# Racket #lang line may come first; the first line after them must be a comment.
def header-ok [lines: list<string>, lang: string] {
    let n = ($lines | length)
    if $n == 0 { return false }
    let l0 = ($lines | get -o 0 | default "" | str trim)
    let after_shebang = (if ($l0 | str starts-with "#!") { $lines | skip 1 } else { $lines })
    let l1 = ($after_shebang | get -o 0 | default "" | str trim)
    let after_lang = (if $lang == "rkt" and ($l1 | str starts-with "#lang") { $after_shebang | skip 1 } else { $after_shebang })
    let first = ($after_lang | where {|l| (($l | str trim) | is-empty) == false } | get -o 0 | default "")
    is-comment-line $first $lang
}

# is-definition says whether one line opens a top-level definition. Only column 0
# counts: an indented form sits inside something else. In Racket a definition is
# a define, struct or module+ form; in Rust a fn, struct, enum, const or impl
# item; in Nushell a def, export def or alias.
#
# An import is NOT a definition. A require, a provide, a use or an import names
# nothing new in this file, and the file's header comment already says what the
# file is and who calls it. Asking for a comment above every import would only
# buy filler, so the lint does not ask for one. The rule the lint keeps is the
# one the owner wrote: every top-level DEFINITION has a comment line directly
# above it.
def is-definition [line: string, lang: string] {
    if ($line | str starts-with " ") { return false }
    if ($line | str starts-with "\t") { return false }
    let t = $line
    if $lang == "rkt" {
        ($t | str starts-with "(define") or ($t | str starts-with "(struct") or ($t | str starts-with "(module+")
    } else if $lang == "rs" {
        ($t | str starts-with "pub fn ") or ($t | str starts-with "pub struct ") or ($t | str starts-with "pub enum ") or ($t | str starts-with "pub const ") or ($t | str starts-with "fn ") or ($t | str starts-with "struct ") or ($t | str starts-with "enum ") or ($t | str starts-with "const ") or ($t | str starts-with "impl ")
    } else {
        ($t | str starts-with "def ") or ($t | str starts-with "export def ") or ($t | str starts-with "alias ")
    }
}

# is-attribute-line says whether one line is a Rust attribute that belongs to
# the definition under it, such as #[derive(...)] or #[serde(...)].
#
# An attribute is part of the definition, not a separate thing: the doc
# comment above it is the comment of that definition. So when the lint looks
# for the comment above a definition it looks above the attributes. This does
# not make the rule looser: the comment still has to be there, and it still
# has to be the line right above the definition and its attributes.
def is-attribute-line [line: string, lang: string] {
    if $lang != "rs" { return false }
    let t = ($line | str trim)
    ($t | str starts-with "#[")
}

# has-comment-above says whether the definition at index i has a comment line
# directly above it. The nearest line above that is not an attribute has to be
# a comment; a blank line is not a comment, so a blank line between the
# comment and the definition breaks the rule.
def has-comment-above [lines: list<string>, i: int, lang: string] {
    let above = ($lines | take $i | reverse | where {|l| not (is-attribute-line $l $lang) } | get -o 0 | default null)
    if $above == null { false } else { is-comment-line $above $lang }
}

# lang-of reads the language from the file's extension.
def lang-of [p: string] {
    if ($p | str ends-with ".rkt") { "rkt" } else if ($p | str ends-with ".rs") { "rs" } else { "nu" }
}

# scan-file reads one file and returns its violations, each with a line and a
# why: a missing header is reported at line 1, and a definition with no comment
# directly above is reported at the definition's own line. A blank line between
# the comment and the definition breaks the rule.
def scan-file [abs_path: string, lang: string] {
    let lines = (open --raw $abs_path | lines)
    let header_violations = (if (header-ok $lines $lang) { [] } else { [{line: 1, why: "no header comment: what it is, why it exists, who calls it"}] })
    let def_violations = ($lines | enumerate | where {|e| is-definition $e.item $lang } | each {|e|
        let i = ($e.index)
        let ok = (has-comment-above $lines $i $lang)
        if $ok { null } else { {line: ($i + 1), why: "top-level definition has no comment line directly above", text: ($lines | get $i)} }
    } | where {|v| $v != null })
    ($header_violations | append $def_violations)
}

# main gathers every .rkt, .rs and .nu file under notation/ and gate/ (skipping
# notation/target/), checks each, prints every violation as file:line: reason,
# and exits non-zero when there is at least one.
def main [] {
    let files = (glob $"($package_dir)/**/*.rkt" | append (glob $"($package_dir)/**/*.rs") | append (glob $"($package_dir)/**/*.nu") | append (glob $"($gate_dir)/**/*.rkt") | append (glob $"($gate_dir)/**/*.rs") | append (glob $"($gate_dir)/**/*.nu") | where {|p| not ($p | str contains "/target/") } | sort)
    let file_count = ($files | length)

    if $file_count == 0 {
        print "NOTHING-TO-CHECK comment-lint: no .rkt, .rs or .nu files exist under notation/ or gate/"
        exit 0
    }

    let violations = ($files | each {|f|
        let lang = (lang-of $f)
        let rel = ($f | path relative-to $project_root)
        scan-file $f $lang | each {|v| {path: $rel, line: $v.line, why: $v.why, text: ($v.text | default "")} }
    } | flatten)
    let bad_count = ($violations | length)

    if $bad_count == 0 {
        print $"OK comment-lint — ($file_count) files checked, every file has a header and every definition a comment above"
        exit 0
    }

    for v in $violations {
        let p = $v.path
        let ln = $v.line
        let why = $v.why
        let text = ($v.text | default "")
        print $"($p):($ln): ($why) — ($text)"
    }
    print $"comment-lint: ($file_count) files checked, ($bad_count) violations"
    exit 1
}
