#!/usr/bin/env nu
# probe.nu -- the phone proof of the send to both agents (TODO item 8).
#
# One job: show, with printed evidence, that a command record and a pane
# selection send from the multiplexer to both agents -- the multiplexer's own
# agent and the editor's agent -- with the same bundle, and that the bundle
# passes the redaction seam on the way.
#
# The fixture: one holder with three panes, named by a layout file -- the
# pane the owner types in (main), the multiplexer's own agent (agent) and the
# editor's agent (editor-agent). The two agent panes run a program that
# writes what it reads to a file, so the proof can read what each agent
# received, byte for byte.
#
# No timers: every wait ends on an event -- the records are read again, and
# the capture files are read again.
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

# held answers the text of a file, with the carriage returns a terminal adds
# taken out: the bundle a terminal received and the bundle the file holds
# are the same thing.
def held [path: string] {
    if ($path | path exists) {
        open --raw $path | str replace --all "\r" ""
    } else {
        ""
    }
}

# wait-for-bundle waits until the file holds the text, reading it again.
def wait-for-bundle [path: string, text: string] {
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

# wait-for-record waits until the records hold the text, reading them again.
def wait-for-record [client: string, state_dir: string, text: string] {
    mut here = false
    mut tries = 0
    while $here == false and $tries < 60 {
        let log = (records $client $state_dir)
        if (($log | to json) | str contains $text) {
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
        $"/tmp/opencode/mux-send-(random uuid)"
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

    # The two agent panes: each one writes what it reads to its own file.
    let agent_file = ($state_dir | path join "agent.txt")
    let editor_file = ($state_dir | path join "editor-agent.txt")
    let agent_script = ($state_dir | path join "agent-capture.sh")
    let editor_script = ($state_dir | path join "editor-agent-capture.sh")
    $"#!/bin/sh\ncat >> '($agent_file)'\n" | save --force $agent_script
    $"#!/bin/sh\ncat >> '($editor_file)'\n" | save --force $editor_script
    chmod +x $agent_script
    chmod +x $editor_script

    # The layout: the pane the owner types in, and the two agent panes.
    let layout = ($state_dir | path join "layout.json")
    {
        direction: "row"
        panes: [
            {name: "main", program: "/bin/sh", tab: "main", weight: 1, cols: 80, rows: 24}
            {name: "agent", program: $agent_script, tab: "main", weight: 1, cols: 80, rows: 24}
            {name: "editor-agent", program: $editor_script, tab: "main", weight: 1, cols: 80, rows: 24}
        ]
    } | to json | save --force $layout

    job spawn {
        try {
            do { ^$holder --state-dir $state_dir --layout $layout --shell /bin/sh }
            | save --force ($state_dir | path join "holder.out")
        } catch { |why| null }
    }

    # The command the owner types in the main pane: the holder keeps it, and
    # the pane prints what it says.
    do -i { ^$client --state-dir $state_dir --op send --data "echo kit-send-marker\n" --pane main } | complete | ignore
    let said = (wait-for-record $client $state_dir "kit-send-marker")
    check "the pane's command is in the log" $said "the command and what the pane printed"

    # The send: the selection, the command record and the why, in one bundle,
    # to both agents.
    do -i { ^$client --state-dir $state_dir --op send-agent --data "the picked line" --pane main } | complete | ignore
    let to_agent = (wait-for-bundle $agent_file "selection: the picked line")
    let to_editor = (wait-for-bundle $editor_file "selection: the picked line")
    check "the multiplexer's own agent received the bundle" $to_agent $"file=($agent_file)"
    check "the editor's agent received the bundle" $to_editor $"file=($editor_file)"

    let agent_text = (held $agent_file)
    let editor_text = (held $editor_file)
    check "the bundle holds the selection" ($agent_text | str contains "selection: the picked line") "the selection travels"
    check "the bundle holds the command record" ($agent_text | str contains "command: echo kit-send-marker") "the command travels"
    check "the bundle holds the why" ($agent_text | str contains "why: the owner sent the picked text to the agents") "the why travels"
    check "both agents received the same bundle" ($agent_text == $editor_text) $"bytes=(($agent_text | str length))"

    let named = (wait-for-record $client $state_dir "editor-agent")
    check "the record names both agents" $named "the delivery says where the bundle went"

    # The seam: a secret in the selection does not leave the multiplexer.
    do -i { ^$client --state-dir $state_dir --op send-agent --data "export api_key=sk-abcdef" --pane main } | complete | ignore
    mut seamed = false
    mut tries = 0
    while $seamed == false and $tries < 60 {
        let text = (held $agent_file)
        if ($text | str contains "[redacted]") {
            $seamed = true
        } else {
            sleep 100ms
            $tries = $tries + 1
        }
    }
    let secret_free = (not ((held $agent_file) | str contains "sk-abcdef"))
    check "the seam holds the secret out" ($seamed and $secret_free) "the value is marked, not carried"

    # the holder goes away with the probe
    let pid_file = ($state_dir | path join "holder.pid")
    if ($pid_file | path exists) {
        let pid = (open --raw $pid_file | str trim)
        do -i { ^kill -TERM $pid }
        print $"PROBE: the holder ($pid) was stopped with the probe"
    }
    rm -rf $state_dir
}
