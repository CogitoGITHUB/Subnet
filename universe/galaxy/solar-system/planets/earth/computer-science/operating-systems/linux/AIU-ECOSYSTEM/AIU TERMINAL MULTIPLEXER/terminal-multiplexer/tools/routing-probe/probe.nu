#!/usr/bin/env nu
# probe.nu -- the phone proof of the routing walk (TODO item 6).
#
# One job: show, with printed evidence, that a key reaches the program in the
# focused pane first, that the multiplexer keeps its reserved prefix in every
# mode, and that the whole walk needs no mouse anywhere.
#
# The fixture: one holder with two panes, named by a layout file -- the pane
# the owner types in (work) and the editor's pane (editor). The editor's
# pane runs a program that writes what it reads to a file, so the proof can
# read what the editor received, byte for byte. The editor's own routing
# inside itself is the editor's half of the walk; here the editor's pane
# stands in for it.
#
# The walk: the keys come in on the pipe and the drawing comes out, exactly
# as the owner's keyboard reaches the client.
#
# No timers: every wait ends on an event -- the file is read again.
#
# The binaries live outside the tree: the build writes into CARGO_TARGET_DIR.
# One place to change them: --bin-dir.

def check [label: string, ok: bool, detail: string] {
    if $ok {
        print $"PROBE: OK ($label) ($detail)"
    } else {
        print $"PROBE: FAIL ($label) ($detail)"
    }
}

# held answers the text of a file, with the carriage returns a terminal adds
# taken out: what the pane received and what the file holds are one thing.
def held [path: string] {
    if ($path | path exists) {
        open --raw $path | str replace --all "\r" ""
    } else {
        ""
    }
}

# wait-for waits until the file holds the text, reading it again.
def wait-for [path: string, text: string] {
    mut here = false
    mut tries = 0
    while $here == false and $tries < 60 {
        if (held $path | str contains $text) {
            $here = true
        } else {
            sleep 100ms
            $tries = $tries + 1
        }
    }
    $here
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
    # One state directory per run: the probe never meets an earlier session.
    let state_dir = (if ($state_dir == null) {
        $"/tmp/opencode/mux-routing-(random uuid)"
    } else {
        $state_dir
    })
    let holder = ($bin_dir | path join "holder")
    let client = ($bin_dir | path join "client")

    print $"PROBE: holder=($holder)"
    print $"PROBE: client=($client)"
    print $"PROBE: state-dir=($state_dir)"

    rm -rf $state_dir
    mkdir $state_dir

    # The editor's pane: a program that writes what it reads to a file.
    let editor_file = ($state_dir | path join "editor.txt")
    let editor_script = ($state_dir | path join "editor-capture.sh")
    $"#!/bin/sh\ncat >> '($editor_file)'\n" | save --force $editor_script
    chmod +x $editor_script

    # The layout: the editor's pane first, so the walk starts in it.
    {
        "direction": "row"
        "panes": [
            { "name": "editor", "tab": "main", "program": $editor_script, "weight": 1, "cols": 80, "rows": 24 }
            { "name": "work", "tab": "main", "program": "/bin/sh", "weight": 1, "cols": 80, "rows": 24 }
        ]
    } | to json | save --force ($state_dir | path join "layout.json")

    job spawn {
        try {
            do {
                ^$holder --state-dir $state_dir --layout ($state_dir | path join "layout.json")
            }
            | save --force ($state_dir | path join "holder.out")
        } catch { |why| null }
    }

    # The walk, part one: the keyboard goes into the editor's pane, and the
    # keys are the editor's -- including the key that would have quit the
    # multiplexer if the multiplexer had taken it.
    let typing = (do -i {
        ^printf "ijq\n" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let typed = $typing.stdout
    let reached = (wait-for $editor_file "jq")
    check "the key reached the program in the focused pane" $reached $"file=($editor_file)"
    check "no key was stolen from the pane" ((held $editor_file) | str contains "q") "the q is the pane's own"
    check "the client is still there" (($typed | str length) > 0) "the screen drew"

    # The walk, part two: the reserved prefix, and the key after it. The
    # prefix is the multiplexer's own in every mode, so the editor's pane
    # never sees it.
    let reserved = (do -i {
        ^printf "ij\n\u{2}l" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let drawn = $reserved.stdout
    let after = (wait-for $editor_file "j\n")
    check "the pane's key after the prefix's predecessor arrived" $after "the editor's pane has the key"

    let pane_text = (held $editor_file)
    check "the reserved prefix did not reach the pane" (not ($pane_text | str contains "\u{2}")) "the prefix is the multiplexer's own"
    check "the key after the prefix did not reach the pane" (not ($pane_text | str contains "l")) "the multiplexer's own key stays the multiplexer's"
    check "the multiplexer acted on the key after the prefix" ($drawn | str contains "the level: 1") "the mode line holds the message"
    check "the mode stayed insert" ($drawn | str contains "INSERT") "the mode line holds the mode"

    # No mouse anywhere: the screen never asks the terminal for mouse input.
    let mouse = ($drawn | str contains "[?1000") or ($drawn | str contains "[?1002") or ($drawn | str contains "[?1006") or ($drawn | str contains "[?1015")
    check "the walk needs no mouse" (not $mouse) "the drawing asks for no mouse"

    # the holder goes away with the probe
    let pid_file = ($state_dir | path join "holder.pid")
    if ($pid_file | path exists) {
        let pid = (open --raw $pid_file | str trim)
        do -i { ^kill -TERM $pid }
        print $"PROBE: the holder ($pid) was stopped with the probe"
    }
    rm -rf $state_dir
}
