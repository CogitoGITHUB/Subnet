#!/usr/bin/env nu
# probe.nu -- the phone proof of asking the editor (TODO item 16).
#
# One job: show, with printed evidence, that the multiplexer asks the editor
# for what the editor owns -- over the editor's own server, over the editor's
# own wire -- and that the answer is the editor's own words.
#
# The fixture: one holder in a scratch directory that is fresh for every run,
# and the REAL editor's own MCP server asked for its read-only dashboard
# capability. Nothing is stubbed here: the words that come back are the
# editor's own.
#
# No timers: the client waits for the holder's socket on the filesystem, and
# the ask ends on the answer the editor's server sends.
#
# The binaries live outside the tree: the build writes into CARGO_TARGET_DIR.
# One place to change them: --bin-dir.

# probe_dir is this directory; the probe sits inside the tools area.
const probe_dir = path self | path dirname

# mux_root is the multiplexer project: two levels up from the probe.
const mux_root = $probe_dir | path dirname | path dirname

# ecosystem is where the other programs live: one level up from the mux.
const ecosystem = $mux_root | path dirname

# editor_mcp is the editor's own server: the file the ask goes to.
const editor_mcp = $ecosystem | path join "AIU EDITOR" | path join "editor"
    | path join "src" | path join "entry" | path join "mcp.rkt"

# editor_capabilities is the editor's own declaration of what each
# capability does: the table the ask is checked against.
const editor_capabilities = $ecosystem | path join "AIU EDITOR" | path join "editor"
    | path join "src" | path join "entry" | path join "capabilities.rkt"

def check [label: string, ok: bool, detail: string] {
    if $ok {
        print $"PROBE: OK ($label) ($detail)"
    } else {
        print $"PROBE: FAIL ($label) ($detail)"
    }
}

# racket_bin is Racket by full path: the phone's PATH names a directory that
# does not exist, and the install lives in opt/racket-full.
def racket_bin [] {
    $env.HOME | path join "opt" | path join "racket-full" | path join "bin" | path join "racket"
}

# the-record answers the record the holder answered with, or nothing.
def the-record [text: string] {
    let lines = ($text | lines | where {|line| ($line | str trim) != "" })
    if ($lines | is-empty) {
        null
    } else {
        $lines | first | from json
    }
}

def main [
    --bin-dir: string
    --state-dir: string
] {
    let bin_dir = (if ($bin_dir == null) {
        "/tmp/opencode/mux-target/debug"
    } else {
        $bin_dir
    })
    # One state directory per run: the probe never meets the session of an
    # earlier run, so what it shows is the session it made.
    let state_dir = (if ($state_dir == null) {
        $"/tmp/opencode/mux-editor-probe-(random uuid)"
    } else {
        $state_dir
    })
    let holder = ($bin_dir | path join "holder")
    let client = ($bin_dir | path join "client")
    let racket = (racket_bin)

    print $"PROBE: holder=($holder)"
    print $"PROBE: client=($client)"
    print $"PROBE: editor's server=($editor_mcp)"
    print $"PROBE: state-dir=($state_dir)"

    rm -rf $state_dir
    mkdir $state_dir

    let holder_out = ($state_dir | path join "holder.out")
    job spawn {
        try {
            do { ^$holder --state-dir $state_dir --shell /bin/sh --cols 80 --rows 24 }
            | save --force $holder_out
        } catch { |why| null }
    }

    # 1. the ask goes to the editor's own server, over the editor's own wire
    let asked = (do -i {
        ^$client --state-dir $state_dir --op editor --editor-mcp-arg $racket --editor-mcp-arg $editor_mcp
    } | complete)
    let record = (the-record $asked.stdout)
    if $record == null {
        check "the holder answers the ask" false $"stderr=($asked.stderr | str trim)"
        return
    }
    check "the holder answers the ask" true $"what=($record | get what)"

    # 2. the ask is a record: it says what was asked, of what
    let inputs = ($record | get inputs)
    check "the ask is a record" (($inputs | get capability) == "dashboard") $"capability=($inputs | get capability)"

    # 3. the answer is the editor's own words
    let data = ($record | get outputs | get editor)
    let text = ($data | get -o text? | default "")
    check "the editor's own words come back" ($text | str contains "the keymap") $"chars=($text | str length)"

    # 4. the answer says how long the ask took: a wait is never a silence
    let took = ($data | get -o took-ms? | default 0)
    check "the answer says how long it took" ($took > 0) $"took-ms=($took)"

    # 5. the capability the multiplexer asked for is read-only in the
    #    editor's own table: the editor's own declaration is the gate
    let declaration = (open --raw $editor_capabilities)
    let read_only = ($declaration | str contains '(capability "dashboard" #f')
    check "the capability asked for is read-only in the editor's own table" $read_only "the editor declares dashboard as a read"

    # 6. an ask with no command is refused BY NAME: nothing is guessed
    let blind = (do -i { ^$client --state-dir $state_dir --op editor } | complete)
    let blind_record = (the-record $blind.stdout)
    let why = (if $blind_record == null {
        ""
    } else {
        $blind_record | get outputs | get editor | get -o why? | default ""
    })
    check "an ask with no command is refused by name" ($why | str contains "there is no command for the editor's server") $"why=($why)"

    # the holder goes away with the probe, and the session directory with it
    let pid_file = ($state_dir | path join "holder.pid")
    if ($pid_file | path exists) {
        let pid = (open --raw $pid_file | str trim)
        do -i { ^kill -TERM $pid }
    }
    rm -rf $state_dir
    print "PROBE: the scratch directory is removed; the next run starts from nothing."
}
