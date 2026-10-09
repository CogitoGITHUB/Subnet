# scripts/tree.nu -- print the repository tree, build output excluded.
#
#   nu scripts/tree.nu [DEPTH]
#
# DEPTH defaults to 3. Directories first, then files, both sorted.
# Excluded: directories named compiled, target or .git, and any path
# ignored by git. Nu built-ins only; no external find, ls or grep.
#
# Why the exclusions matter (D-027): compiled/ and target/ hold build
# output, not sources, and they bury the real shape of the tree.

# Never shown, at any depth.
const SKIP_DIRS = ["compiled" "target" ".git"]

# -> string, current UTC instant, second precision
def utc [] {
    date now | format date "%Y-%m-%dT%H:%M:%SZ"
}

# -> list, the gitignore patterns, one per line, no comments or blanks
def ignore-patterns [root] {
    let f = ($root | path join ".gitignore")
    if not ($f | path exists) {
        return []
    }
    (open --raw $f)
    | lines
    | where {|l| (($l | str trim) | is-not-empty) and not (($l | str trim) | str starts-with "#")}
    | each {|l| $l | str trim}
}

# string string -> bool, true when path matches a gitignore pattern.
# Supports the two forms this repo uses: a bare name (compiled/) and a
# path prefix (tui/target/). Written as one pipeline, because "or" is a
# keyword and cannot start a continuation line.
def ignored? [path pats] {
    $pats | any {|p|
        let clean = ($p | str trim)
        let bare = ($clean | str replace -a "/$" "")
        [$path == $clean, $path == $bare,
         ($path | str starts-with $"($clean)/"),
         ($path | str starts-with $"($bare)/")] | any {|b| $b }
    }
}

# string int (listof string) -> list, [name depth] entries under dir
def walk [root depth limit pats] {
    if $depth > $limit {
        return []
    }
    let here = ($root | path expand)
    # ls already yields name/type rows; transforming them drops the columns
    let entries = (ls $here)
    let kept = ($entries | where {|e|
        let nm = ($e.name | path basename)
        let skip_dir = ($SKIP_DIRS | any {|s| $nm == $s })
        let skip_ign = (ignored? ($e.name | path expand) $pats)
        not ($skip_dir or $skip_ign)
    })
    let dirs = ($kept | where type == "dir" | get name | sort-by {|d| $d | path basename })
    let files = ($kept | where type == "file" | get name | sort-by {|f| $f | path basename })
    # built functionally: an accumulator would need mut, which cannot be
    # captured inside a closure, and walk is recursive
    let dir_rows = ($dirs | each {|d|
        [{name: $d, depth: $depth}] | append (walk $d ($depth + 1) $limit $pats) })
    let file_rows = ($files | each {|f| [{name: $f, depth: $depth}] })
    $dir_rows | append $file_rows | flatten
}

def show-tree [] {
    print $"[tree] start utc=(utc)"
    let raw = ($env | get -o CYBERDECK_TREE_DEPTH? | default "3")
    let limit = ($raw | into int)
    let root = ($nu | get -o cwd? | default ".")
    let pats = (ignore-patterns $root)
    let total = (timeit {
        let rows = (walk $root 1 $limit $pats)
        let prefix = ($root | path expand)
        for r in $rows {
            let rel = ($r.name | str replace $"($prefix)/" "")
            print $"($rel)"
        }
        print $"[tree] ($rows | length) entries, depth ($limit)"
    })
    print $"[tree] end utc=(utc) after=(($total | into int))ns"
}

show-tree
