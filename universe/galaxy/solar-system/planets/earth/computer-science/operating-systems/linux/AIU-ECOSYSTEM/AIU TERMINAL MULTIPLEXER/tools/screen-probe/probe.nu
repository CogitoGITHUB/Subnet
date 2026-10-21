#!/usr/bin/env nu
# probe.nu -- the phone proof of the screen (TODO item 5, the drawing, and
# item 6, the keys).
#
# One job: show, with printed evidence, that the screen draws the panes of a
# layout on one terminal, that the mode line says which mode the owner is in,
# that a key in insert mode reaches the focused pane's own program, and that
# one window size reaches every pane of the session.
#
# No timers: every wait ends on an event — the client's wait for the holder's
# socket ends on the filesystem event that creates it.
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

# records answers the records of the session, read through the client.
def records [client: string, state_dir: string] {
    let read = (do -i { ^$client --state-dir $state_dir --op read --since 0 } | complete)
    ($read.stdout | split row (char newline) | where {|line| ($line | str trim) != "" } | each {|line| $line | from json })
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
        $"/tmp/opencode/mux-screen-(random uuid)"
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

    # The layout: two panes, in two tabs.
    let layout = {
        "direction": "row"
        "panes": [
            { "name": "work", "tab": "main", "program": "/bin/sh", "weight": 2, "cols": 80, "rows": 24 }
            { "name": "notes", "tab": "other", "program": "/bin/sh", "weight": 1, "cols": 80, "rows": 24 }
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

    # The screen: the keys come in on the pipe, the drawing comes out.
    # The first screen opens the keymap explorer with Space, so the drawing
    # holds the panel. The second screen types into the pane: E puts the
    # keyboard in the pane, and the text after it belongs to the program.
    let explorer = (do -i {
        ^printf " " | ^$client --state-dir $state_dir --op screen
    } | complete)
    let drawn = $explorer.stdout

    let typing = (do -i {
        ^printf "i echo from-the-screen-pane\n" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let typed = $typing.stdout

    # 1. the screen draws the panes of the layout
    check "the screen draws the pane" ($drawn | str contains "work") "the drawing holds the name"
    check "the screen draws the tab bar" ($drawn | str contains "[main]") "the drawing holds the tab"
    check "the screen draws a frame" ($drawn | str contains "+-") "the drawing holds a frame"

    # 2. the tab bar names the tabs and marks the one the owner stands in
    check "the tab bar names the other tab" ($drawn | str contains "other") "the tab bar holds the tab"

    # 3. the mode line says where the owner stands
    check "the screen starts in visual mode" ($drawn | str contains "VISUAL") "the mode line holds the mode"
    check "the mode line says the focused pane" ($drawn | str contains "pane work") "the mode line holds the pane"
    check "the typing screen is in insert mode" ($typed | str contains "INSERT") "the mode line holds the mode"

    # 4. the keymap explorer opens on Space and shows the keys
    check "the keymap explorer opens" ($drawn | str contains "the keymap") "the panel holds its title"
    check "the explorer shows the keys" ($drawn | str contains "Space") "the panel holds a key"
    check "the explorer shows what a key means" ($drawn | str contains "type into the focused pane") "the panel holds a description"

    # 5. the events strip says what happened
    check "the events strip is drawn" ($drawn | str contains "events") "the strip holds the count"

    # 5. the keys reached the focused pane, and the shell answered
    let held = (records $client $state_dir)
    let sends = ($held | where {|r| ($r | get -o what | default "") == "the data went to the shell" } | length)
    check "the key reached the focused pane" ($sends > 0) $"sends=($sends)"

    let answers = ($held | where {|r| ($r | get -o who | default "") == "work" } | length)
    check "the pane's shell answered" ($answers > 0) $"records=($answers)"

    # The shell answers in its own time: the probe reads the records again
    # until the answer is there. Every wait ends on an event — the records
    # are read again — and never on a clock.
    mut said = 0
    mut tries = 0
    while $said == 0 and $tries < 20 {
        let again = (records $client $state_dir)
        $said = ($again | where {|r| ($r | get -o outputs | default {} | get -o text | default "") | str contains "from-the-screen-pane" } | length)
        $tries = $tries + 1
    }
    check "what the shell said is on the screen's wire" ($said > 0) $"hits=($said)"

    # 6. one window size reached every pane
    let resizes = ($held | where {|r| ($r | get -o what | default "") == "the window changed" } | length)
    check "the window size reached the session" ($resizes > 0) $"resizes=($resizes)"

    let told = ($held | where {|r| ($r | get -o what | default "") == "the window changed" } | last)
    let panes_told = ($told | get -o outputs | default {} | get -o panes | default [] | length)
    check "every pane was told the size" ($panes_told >= 2) $"panes=($panes_told)"

    # the holder goes away with the probe
    let pid_file = ($state_dir | path join "holder.pid")
    if ($pid_file | path exists) {
        let pid = (open --raw $pid_file | str trim)
        do -i { ^kill -TERM $pid }
        print $"PROBE: the holder ($pid) was stopped with the probe"
    }
    rm -rf $state_dir
}
