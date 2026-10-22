#!/usr/bin/env nu
# probe.nu -- the phone proof of the agent's hands (TODO item 23).
#
# One job: show, with printed evidence, that an AI agent can drive the
# multiplexer the way the owner does -- the tabs, the splits, the scroll and
# the copy -- through the MCP server, and that a change without the human's
# token is refused by name.
#
# No timers: every wait ends on an event. The screen stays attached on a
# pipe that is never closed, and the proof reads what the server said and
# what the holder recorded.
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

# lines-of answers the answers of the server, one per line, without the
# empty ones.
def lines-of [text: string] {
    $text | lines | where {|line| ($line | str trim) != "" }
}

# answer-of answers the answer with that id, parsed.
def answer-of [text: string, id: int] {
    let wanted = ($"\"id\":($id)")
    let line = (lines-of $text | where {|l| $l | str contains $wanted } | first)
    if $line == null {
        null
    } else {
        $line | from json
    }
}

# text-of answers the text inside a tool answer: the envelope the tool sent.
def text-of [answer: any] {
    $answer | get -o result | get -o content | get -o 0 | get -o text | default ""
}

# envelope-of answers the envelope of a tool answer: the data the tool sent.
def envelope-of [answer: any] {
    text-of $answer | from json
}

# view-of answers the view of the screen: the tabs, the panes, the scroll and
# the ring, as the screen said.
def view-of [answer: any] {
    envelope-of $answer | get -o data | get -o data | default {}
}

# panes-of answers the panes of a view.
def panes-of [view: any] {
    $view | get -o panes | default []
}

# ask-server sends the requests to the MCP server and answers what it said.
def ask-server [server: string, sessions_dir: string, requests: list] {
    let said = ($requests | str join (char newline) | ^$server --sessions-dir $sessions_dir | complete)
    $said.stdout
}

# call-control is the request of one control: the words, and the token when
# the human gave one.
def call-control [id: int, session: string, words: list, token: string] {
    let said = (if ($token == "") { "" } else { $",\"confirm\":\"($token)\"" })
    let list = ($words | each {|word| $"\"($word)\"" } | str join ",")
    $"{\"jsonrpc\":\"2.0\",\"id\":($id),\"method\":\"tools/call\",\"params\":{\"name\":\"multiplexer_control\",\"arguments\":{\"session\":\"($session)\",\"words\":[($list)]($said)}}}"
}

# call-view is the request of the agent's read of the screen.
def call-view [id: int, session: string] {
    $"{\"jsonrpc\":\"2.0\",\"id\":($id),\"method\":\"tools/call\",\"params\":{\"name\":\"multiplexer_view\",\"arguments\":{\"session\":\"($session)\"}}}"
}

def main [
    --bin-dir: string
    --sessions-dir: string
] {
    let bin_dir = (if ($bin_dir == null) {
        "/tmp/opencode/mux-target/debug"
    } else {
        $bin_dir
    })
    # One sessions directory per run: the probe never meets the session of an
    # earlier run.
    let sessions_dir = (if ($sessions_dir == null) {
        $"/tmp/opencode/mux-sessions-(random uuid)"
    } else {
        $sessions_dir
    })
    let holder = ($bin_dir | path join "holder")
    let client = ($bin_dir | path join "client")
    let server = ($bin_dir | path join "mux-mcp")

    print $"PROBE: holder=($holder)"
    print $"PROBE: server=($server)"
    print $"PROBE: sessions-dir=($sessions_dir)"

    let session = "work"
    let state_dir = ($sessions_dir | path join $session)
    mkdir $state_dir
    # The human's token: the server reads it, and the holder reads it, and a
    # change without it is refused by name.
    "the-human-token" | save --force ($sessions_dir | path join "token")

    job spawn {
        try {
            do { ^$holder --state-dir $state_dir --shell /bin/sh --cols 80 --rows 24 }
            | save --force ($state_dir | path join "holder.out")
        } catch { |why| null }
    }

    # The screen: the owner's own view of the session. It reads its keys on a
    # pipe that is never written to and never closed, so it stays attached and
    # the agent's words have a screen to run on.
    let fifo = ($state_dir | path join "keys.fifo")
    mkfifo $fifo
    job spawn {
        try {
            do { ^cat $fifo | ^$client --state-dir $state_dir --op screen }
            | save --force ($state_dir | path join "screen.out")
        } catch { |why| null }
    }

    # The wait for the screen: the records are read again until the attach is
    # there. Every wait ends on an event -- the records are read again -- and
    # never on a clock.
    let read_records = $"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"multiplexer_records\",\"arguments\":{\"session\":\"($session)\",\"since\":0}}}"
    mut attached = 0
    mut tries = 0
    while $attached == 0 and $tries < 40 {
        let again = (ask-server $server $sessions_dir [$read_records])
        let records = (answer-of $again 1)
        let log = (envelope-of $records | get -o data | get -o records | default [])
        $attached = ($log | where {|r| $r | get -o why | default "" | str contains "the client attached" } | length)
        $tries = $tries + 1
    }
    check "the screen is attached to the holder" ($attached > 0) $"attaches=($attached)"

    # The tools the agent has: the read and the change.
    let listed = (ask-server $server $sessions_dir [
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}"
    ])
    let names = ((answer-of $listed 1) | get -o result | get -o tools | each {|t| $t | get name } | str join ",")
    check "the server lists the agent's tools" (($names | str contains "multiplexer_control") and ($names | str contains "multiplexer_view")) $"tools=($names)"

    # A change without the human's token is refused by name.
    let refused = (ask-server $server $sessions_dir [(call-control 1 $session ["tab" "new"] "")])
    let refusal_text = (envelope-of (answer-of $refused 1))
    let refusal_ok = ($refusal_text | get -o ok)
    let refusal_rule = ($refusal_text | get -o refusal | get -o rule | default "")
    check "a change without the token is refused" ($refusal_ok == false) $"rule=($refusal_rule)"

    # The agent reads the screen: the tabs, the panes, the scroll and the ring.
    let read = (ask-server $server $sessions_dir [(call-view 1 $session)])
    let view = (view-of (answer-of $read 1))
    let panes = (panes-of $view)
    check "the agent reads the screen" (($panes | length) > 0) $"panes=($panes | length) tabs=($view | get -o tabs | default [])"

    # The agent adds a tab: the owner's own word, on the owner's own screen.
    let added = (ask-server $server $sessions_dir [(call-control 1 $session ["tab" "new"] "the-human-token")])
    let added_envelope = (envelope-of (answer-of $added 1))
    let added_ok = ($added_envelope | get -o ok)
    check "the agent adds a tab" ($added_ok == true) $"ok=($added_ok)"

    # The agent splits a pane: a new pane in the tab the owner stands in.
    let split = (ask-server $server $sessions_dir [(call-control 1 $session ["pane" "new"] "the-human-token")])
    let split_ok = (envelope-of (answer-of $split 1) | get -o ok)
    check "the agent splits a pane" ($split_ok == true) $"ok=($split_ok)"

    # The pane talks, so there is text to copy: the shell is asked to say a
    # hundred lines.
    let said_many = (ask-server $server $sessions_dir [
        $"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"multiplexer_send\",\"arguments\":{\"session\":\"($session)\",\"data\":\"seq 1 100\\n\",\"confirm\":\"the-human-token\"}}}"
    ])
    let said_ok = (envelope-of (answer-of $said_many 1) | get -o ok)
    check "the agent says to the shell" ($said_ok == true) $"ok=($said_ok)"

    # The wait for the shell: the view is read again until the pane holds
    # what the shell said. The wait ends on an event -- the view is read
    # again.
    mut said_it = false
    mut tries = 0
    while $said_it == false and $tries < 40 {
        let again = (ask-server $server $sessions_dir [(call-view 1 $session)])
        let again_view = (view-of (answer-of $again 1))
        let again_panes = (panes-of $again_view)
        $said_it = (($again_panes | first | get -o lines | default 0) > 20)
        $tries = $tries + 1
    }
    check "the agent sees what the shell said" $said_it $"seen=($said_it)"

    # The view now holds the tabs and the panes the agent made.
    let after = (ask-server $server $sessions_dir [(call-view 1 $session)])
    let after_view = (view-of (answer-of $after 1))
    let tabs = ($after_view | get -o tabs | default [])
    let after_panes = (panes-of $after_view)
    let first_pane = ($after_panes | first | get -o name | default "")
    let second_pane = ($after_panes | get 1 | get -o name | default "")
    check "the tab the agent added is there" (($tabs | length) > 1) $"tabs=($tabs | str join ",")"
    check "the pane the agent split is there" (($after_panes | length) > 1) $"panes=($after_panes | length)"

    # The agent scrolls: the page keys, the owner's own keys.
    let scrolled = (ask-server $server $sessions_dir [(call-control 1 $session ["scroll" "up"] "the-human-token")])
    let scrolled_ok = (envelope-of (answer-of $scrolled 1) | get -o ok)
    let scroll_view = (view-of (answer-of $scrolled 1))
    let scroll = (panes-of $scroll_view | first | get -o scroll | default 0)
    check "the agent scrolls the pane" (($scrolled_ok == true) and ($scroll > 0)) $"scroll=($scroll)"

    # The agent copies a part: the lines of a pane, into the multiplexer's own
    # ring -- the ring the owner's own copy fills.
    let copied = (ask-server $server $sessions_dir [(call-control 1 $session ["copy" $first_pane "1" "2"] "the-human-token")])
    let copied_view = (view-of (answer-of $copied 1))
    let ring = ($copied_view | get -o ring | default [])
    check "the agent copies a part into the ring" (($ring | length) > 0) $"ring=($ring | first | default "")"

    # The agent moves the focus: the owner's own words.
    let focused = (ask-server $server $sessions_dir [(call-control 1 $session ["focus" $second_pane] "the-human-token")])
    let focused_view = (view-of (answer-of $focused 1))
    let focus_name = ($focused_view | get -o focused | default "")
    check "the agent moves the focus" ($focus_name == $second_pane) $"focused=($focus_name)"

    # The agent pastes the copy into the other pane: the text goes to that
    # pane's own program, and the holder records the send.
    let pasted = (ask-server $server $sessions_dir [(call-control 1 $session ["paste" $second_pane] "the-human-token")])
    let pasted_ok = (envelope-of (answer-of $pasted 1) | get -o ok)
    check "the agent pastes into the other pane" ($pasted_ok == true) $"ok=($pasted_ok)"

    let records = (ask-server $server $sessions_dir [$read_records])
    let log = (envelope-of (answer-of $records 1) | get -o data | get -o records | default [])
    let sent = ($log | where {|r| $r | get -o inputs | get -o pane | default "" | str contains $second_pane } | length)
    check "the holder recorded the paste" ($sent > 0) $"sends=($sent)"

    # the holder goes away with the probe
    let pid_file = ($state_dir | path join "holder.pid")
    if ($pid_file | path exists) {
        let pid = (open --raw $pid_file | str trim)
        do -i { ^kill -TERM $pid }
        print $"PROBE: the holder ($pid) was stopped with the probe"
    }
    rm -rf $sessions_dir
}
