#!/usr/bin/env nu
# banned-words-lint -- the naming law, made enforceable.
#
# plan/NAMING-REGISTER.org states the law: a name states the one job it
# does, and core, main, server, backends, handler, manager and tmp are
# banned everywhere, in paths and in definitions. A law with no gate is a
# wish, so this is the gate.
#
# It reads git-TRACKED paths rather than the filesystem. A test run leaves
# empty directories behind (measured: package-manager/src/git/tmp appeared
# while the suite ran) and build output litters the tree; a lint that goes
# red on either teaches people to ignore it, which costs more than it buys.
#
# Matching is by SEGMENT, never substring: bats-core is two words and
# cores is a word that is fine, so only a whole word counts.

const BANNED = [core main server backends handler manager tmp]

# The example declarations under docs/ name REAL upstream packages --
# bats-core, cjson, lua. Those words are data read from the outside world,
# not names we chose for our things, so the law does not reach them.
const FIXTURE_ROOTS = ['docs/examples/', 'docs/examples-bad/']

# string -> list<string>, the words a name is made of
def segments [name: string] {
    $name | split row -r '[-_.]' | where {|s| $s != '' } | each {|s| $s | str lowercase }
}

# string -> list<string>, the banned words in a name, if any
def banned-in [name: string] {
    segments $name | where {|s| ($BANNED | any {|b| $b == $s }) }
}

# The product is called package-manager. That is one name for one thing,
# not a component called "manager", so it is the single allowed word.
def allowed-word [name: string] {
    ($name | str downcase) == 'package-manager'
}

# string -> string, the identifier a definition introduces, or "". Reads
# the NAME, not the whole line, so a body that merely mentions a word is
# not a violation and a definition that IS the word is.
def defined-name [line: string] {
    let t = ($line | str trim)
    let r = ($t | parse -r '^\((?:define|define-values|define-syntax|struct)\s+\(?(?<name>[^\s()]+)')
    if ($r | is-empty) { '' } else { $r.0.name }
}

def main [] {
    let files = (git ls-files | lines | where {|f| $f != '' })
    mut out = []
    for f in $files {
        if ($FIXTURE_ROOTS | any {|r| $f | str starts-with $r }) { continue }
        for part in ($f | path split) {
            if (allowed-word $part) { continue }
            for w in (banned-in $part) {
                $out = ($out | append $"banned-words-lint: ($w) ($f)")
            }
        }
        # Definitions only exist in Racket, so only those files are opened.
        if not ($f | str ends-with '.rkt') { continue }
        let ls = (open --raw $f | lines)
        for l in ($ls | enumerate) {
            let name = (defined-name $l.item)
            if $name == '' { continue }
            for w in (banned-in $name) {
                let n = ($l.index + 1)
                $out = ($out | append $"banned-words-lint: ($w) ($f):($n)")
            }
        }
    }
    print $"banned-words-lint: ($files | length) files, ($out | length) violations"
    for v in $out { print $v }
    if ($out | length) > 0 { exit 1 }
}
