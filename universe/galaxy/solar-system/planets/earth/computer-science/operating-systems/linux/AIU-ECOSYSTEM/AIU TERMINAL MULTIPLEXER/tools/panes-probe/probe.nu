#!/usr/bin/env nu
# probe.nu -- the phone proof of the panes (TODO item 5).
#
# One job: show, with printed evidence, that a layout file opens the panes it
# names, that every pane's shell is alive, that each pane's output is
# recorded under that pane's own name, and that a send aimed at one pane
# reaches that pane and not the other.
#
# No timers: every wait ends on an event — the client's wait for the
# holder's socket ends on the filesystem event that creates it.
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

# first-record answers the first record a client printed, or nothing.
def first-record [text: string] {
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
    # One state directory per run: the probe never meets an earlier session.
    let state_dir = (if ($state_dir == null) {
        $"/tmp/opencode/mux-panes-(random uuid)"
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

    # The layout: two panes, by name, with the programs they run.
    let layout = {
        "direction": "row"
        "panes": [
            { "name": "work", "program": "/bin/sh", "weight": 2, "cols": 80, "rows": 24 }
            { "name": "agent", "program": "/bin/sh", "weight": 1, "cols": 80, "rows": 24 }
        ]
    } | to json | save --force ($state_dir | path join "layout.json")

    let holder_out = ($state_dir | path join "holder.out")
    job spawn {
        try {
            do {
                ^$holder --state-dir $state_dir --layout ($state_dir | path join "layout.json")
            }
            | save --force $holder_out
        } catch { |why| null }
    }

    # 1. the state names every pane of the layout
    let state = (do -i { ^$client --state-dir $state_dir --op state } | complete)
    let held = (first-record $state.stdout)
    if $held == null {
        check "the holder answers the state" false $"stderr=($state.stderr | str trim)"
        return
    }
    let panes = ($held | get outputs | get panes)
    let names = ($panes | each {|pane| $pane | get name } | str join ",")
    check "the layout opened its panes" (($panes | length) == 2) $"panes=($names)"

    let alive = ($panes | where {|pane| $pane | get alive } | length)
    check "every pane's shell is alive" ($alive == 2) $"alive=($alive)"

    # 2. a send aimed at one pane reaches that pane
    let to_work = (do -i {
        ^$client --state-dir $state_dir --op send --pane work --data "echo from-the-work-pane\n"
    } | complete)
    check "a send reaches the pane it names" ($to_work.exit_code == 0) $"rc=($to_work.exit_code)"

    let to_agent = (do -i {
        ^$client --state-dir $state_dir --op send --pane agent --data "echo from-the-agent-pane\n"
    } | complete)
    check "a send reaches the other pane too" ($to_agent.exit_code == 0) $"rc=($to_agent.exit_code)"

    # 3. each pane's output is recorded under that pane's own name
    let read = (do -i { ^$client --state-dir $state_dir --op read --since 0 } | complete)
    let lines = ($read.stdout | split row (char newline) | where {|line| ($line | str trim) != "" })
    let records = ($lines | each {|line| $line | from json })
    let work_hits = ($records | where {|r| ($r | get -o who | default "") == "work" } | length)
    let agent_hits = ($records | where {|r| ($r | get -o who | default "") == "agent" } | length)
    check "the work pane's records carry its name" ($work_hits > 0) $"records=($work_hits)"
    check "the agent pane's records carry its name" ($agent_hits > 0) $"records=($agent_hits)"

    # the holder goes away with the probe
    let pid_file = ($state_dir | path join "holder.pid")
    if ($pid_file | path exists) {
        let pid = (open --raw $pid_file | str trim)
        do -i { ^kill -TERM $pid }
        print $"PROBE: the holder ($pid) was stopped with the probe"
    }
    rm -rf $state_dir
}
