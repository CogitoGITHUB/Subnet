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

# last-drawing answers the last drawing of a screen: the screen draws
# again after every event, and the last one is the state it stands in.
def last-drawing [out: string] {
    ($out | split row "\u{1b}[?25l" | last)
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

    # 7. the key that opens the agent beside the pane, with the context of
    #    that pane attached. The agent is a plain script here, so the proof
    #    is about the multiplexer and not about the phone's memory.
    let agent = ($state_dir | path join "agent.sh")
    '#!/bin/sh
for a in "$@"; do echo "ARG $a"; done' | save --force $agent
    chmod +x $agent

    let opened = (do -i {
        ^printf "po" | ^$client --state-dir $state_dir --op screen --agent-program $agent
    } | complete)

    let after = (records $client $state_dir)
    let sends = ($after | where {|r| ($r | get -o what | default "") == "the context went to the agent" })
    check "the send is a record" (($sends | length) > 0) $"records=($sends | length)"

    let bundle = ($sends | last | get -o result | default {})
    let header = ($bundle | get -o document | default {} | get -o header | default {})
    check "the bundle names the multiplexer" (($header | get -o program | default "") == "aiu-multiplexer") $"header=($header)"
    check "the bundle names the agent" (($header | get -o target | default "") == "agent.sh") $"target=($header | get -o target | default "")"

    let panes = ($after | where {|r| (($r | get -o what | default "") == "a pane opened") and (($r | get -o inputs | default {} | get -o pane | default "") == "agent") })
    check "the agent pane opened" (($panes | length) > 0) $"panes=($panes | length)"

    # The program got the context: the script prints what it was given. The
    # wait ends on the records arriving, never on a clock.
    mut agent_hits = 0
    mut agent_tries = 0
    while $agent_hits == 0 and $agent_tries < 20 {
        let again = (records $client $state_dir)
        $agent_hits = ($again | where {|r| ($r | get -o outputs | default {} | get -o text | default "") | str contains "boundary: 1  program: aiu-multiplexer" } | length)
        $agent_tries = $agent_tries + 1
    }
    check "the context reached the agent program" ($agent_hits > 0) $"hits=($agent_hits)"

    # 8. the git: the panel shows what the shared layer read, and the
    #    layer only reads. The holder's own directory is the repository
    #    that is asked about, so the answer is a real one.
    let gitted = (do -i {
        ^printf "go" | ^$client --state-dir $state_dir --op screen
    } | complete)

    let after_git = (records $client $state_dir)
    let gits = ($after_git | where {|r| ($r | get -o what | default "") == "the git state was read" })
    check "the git is read as a record" (($gits | length) > 0) $"records=($gits | length)"

    let gdata = ($gits | last | get -o outputs | default {} | get -o git | default {})
    let gstatus = ($gdata | get -o status | default {})
    let ghead = ($gstatus | get -o head | default "")
    check "the git names the branch it stands on" ($ghead != "") $"head=($ghead)"

    let gworktrees = ($gdata | get -o repository | default {} | get -o worktrees | default [] | length)
    check "the git names the worktrees" ($gworktrees > 0) $"worktrees=($gworktrees)"

    # The panel drew it: the drawing holds the git's own words.
    let gdrawn = ($gitted.stdout | default "")
    check "the panel shows the git" ($gdrawn | str contains "the git") $"drawn=($gdrawn | str length)"

    # 9. the worktree browser: every worktree of the repository, one
    #    line each, and the path under it.
    let worktreed = (do -i {
        ^printf "gw" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let wdrawn = ($worktreed.stdout | default "")
    check "the worktree browser draws the worktrees" ($wdrawn | str contains "the worktrees") $"drawn=($wdrawn | str length)"

    # 10. the selection: the mode opens on the focused pane, the point
    #    moves over the visible text, the mark is the anchor, the copy
    #    puts the text in the multiplexer's own ring, and the escape
    #    does nothing at all.
    let picked = (do -i {
        ^printf "v\u{1b}[Cm\u{1b}[C\u{1b}[Cy" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let pdrawn = ($picked.stdout | default "")
    check "the selection opens its own mode" ($pdrawn | str contains "SELECT") $"drawn=($pdrawn | str length)"
    check "the selection copies the region" ($pdrawn | str contains "the region is copied") $"drawn=($pdrawn | str length)"
    check "the selection marks the region" ($pdrawn | str contains "\u{1b}[7m") $"drawn=($pdrawn | str length)"

    let escaped = (do -i {
        ^printf "v\u{1b}[Cm\u{1b}[C\u{1b}[C\u{1b}" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let edrawn = ($escaped.stdout | default "")
    check "the escape leaves the selection and does nothing" ($edrawn | str contains "nothing was copied") $"drawn=($edrawn | str length)"
    check "the escape leaves the mode" ($edrawn | str contains "VISUAL") $"drawn=($edrawn | str length)"

    # 11. the workspace: the engine behind the holder holds the
    #    workspaces, their projects and the context. The multiplexer asks
    #    the engine and writes through it, and the mode line names the
    #    workspace and the project.
    let worked = (do -i {
        ^printf ":workspace create the-work\n:workspace project the-first\n:workspace open the-first\n" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let wdrawn = ($worked.stdout | default "")
    check "the mode line names the workspace" ($wdrawn | str contains "ws:the-work") $"drawn=($wdrawn | str length)"
    check "the mode line names the project" ($wdrawn | str contains "pr:the-first") $"drawn=($wdrawn | str length)"

    let after_workspace = (records $client $state_dir)
    let workspaces = ($after_workspace | where {|r| ($r | get -o what | default "") == "the workspace was read" })
    check "the workspace is read as a record" (($workspaces | length) > 0) $"records=($workspaces | length)"

    let wdata = ($workspaces | last | get -o outputs | default {} | get -o workspace | default {})
    let wprojects = ($wdata | get -o workspaces | default [] | get -o 0 | default {} | get -o projects | default [] | length)
    check "the workspace holds the project" ($wprojects > 0) $"projects=($wprojects)"

    let wproject = ($wdata | get -o workspaces | default [] | get -o 0 | default {} | get -o projects | default [] | get -o 0 | default {} | get -o name | default "")
    check "the workspace names the project" ($wproject == "the-first") $"project=($wproject)"

    # 12. the levels: the screen's own furniture is rows, and the owner
    #     hides them. Level 2 is the default: the mode row, the
    #     specifics and the events. One key less leaves the mode row
    #     alone; one key more hides everything, the tab bar with it.
    let less = (do -i {
        ^printf "l" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let ldrawn = (last-drawing ($less.stdout | default ""))
    check "one level less keeps the mode row" ($ldrawn | str contains "VISUAL") $"drawn=($ldrawn | str length)"
    check "one level less hides the specifics" (not ($ldrawn | str contains "pane work --")) $"drawn=($ldrawn | str length)"

    let least = (do -i {
        ^printf "ll" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let mdrawn = (last-drawing ($least.stdout | default ""))
    check "level zero hides the mode row" (not ($mdrawn | str contains "VISUAL")) $"drawn=($mdrawn | str length)"
    check "level zero hides the tab bar" (not ($mdrawn | str contains "[main]")) $"drawn=($mdrawn | str length)"

    let more = (do -i {
        ^printf "L" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let odrawn = (last-drawing ($more.stdout | default ""))
    check "one level more shows the hints" ($odrawn | str contains "l:less") $"drawn=($odrawn | str length)"

    # 13. the scroll: the wheel is refused, so the page keys scroll, and
    #     the pick restarts over the fresh text. The pane says a hundred
    #     numbered lines first, so a page is a page.
    let many = (do -i {
        ^printf 'i i=1; while [ $i -le 100 ]; do echo scroll-line-$i; i=$((i+1)); done\n' | ^$client --state-dir $state_dir --op screen
    } | complete)
    # The shell answers in its own time: the records are read again until
    # the lines are there. Every wait ends on an event.
    mut said = 0
    mut tries = 0
    while $said == 0 and $tries < 30 {
        let again = (records $client $state_dir)
        $said = ($again | where {|r| ($r | get -o outputs | default {} | get -o text | default "") | str contains "scroll-line-100" } | length)
        $tries = $tries + 1
    }
    check "the pane said a hundred lines" ($said > 0) $"hits=($said)"

    let paged = (do -i {
        ^printf "\u{1b}[5~" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let pgdrawn = (last-drawing ($paged.stdout | default ""))
    check "the page key scrolls the view" ($pgdrawn | str contains "one page up") $"drawn=($pgdrawn | str length)"
    check "the view shows the older words" (not ($pgdrawn | str contains "scroll-line-100")) $"drawn=($pgdrawn | str length)"
    check "the view still shows the pane" ($pgdrawn | str contains "scroll-line-") $"drawn=($pgdrawn | str length)"

    # the pick restarts over the fresh text: the mark named a line of the
    # old window, and that line is not there any more
    let marked = (do -i {
        ^printf "vm\u{1b}[By" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let mkdrawn = (last-drawing ($marked.stdout | default ""))
    check "the pick copies a region over the visible text" ($mkdrawn | str contains "the region is copied") $"drawn=($mkdrawn | str length)"

    let restarted = (do -i {
        ^printf "vm\u{1b}[5~\u{1b}[By" | ^$client --state-dir $state_dir --op screen
    } | complete)
    let rsdrawn = (last-drawing ($restarted.stdout | default ""))
    check "the pick restarts over the fresh text" ($rsdrawn | str contains "there is no region") $"drawn=($rsdrawn | str length)"

    # the holder goes away with the probe
    let pid_file = ($state_dir | path join "holder.pid")
    if ($pid_file | path exists) {
        let pid = (open --raw $pid_file | str trim)
        do -i { ^kill -TERM $pid }
        print $"PROBE: the holder ($pid) was stopped with the probe"
    }
    rm -rf $state_dir
}
