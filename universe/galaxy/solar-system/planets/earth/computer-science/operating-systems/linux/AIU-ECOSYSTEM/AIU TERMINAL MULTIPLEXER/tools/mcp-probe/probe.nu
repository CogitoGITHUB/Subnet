#!/usr/bin/env nu
# probe.nu -- the phone proof of the agent surface (TODO item 4).
#
# One job: show, with printed evidence, that an AI agent can drive the
# multiplexer through the MCP server — that it can list the sessions, read
# the records, and send to a session's shell, and that a send without the
# human's token is refused by name.
#
# No timers: every wait ends on an event. The server answers on the standard
# output as it answers, and the proof reads what it said.
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
    let server = ($bin_dir | path join "mux-mcp")

    print $"PROBE: holder=($holder)"
    print $"PROBE: server=($server)"
    print $"PROBE: sessions-dir=($sessions_dir)"

    let session = "work"
    let state_dir = ($sessions_dir | path join $session)
    mkdir $state_dir
    # The human's token: the server reads it, and a send without it is
    # refused by name.
    "the-human-token" | save --force ($sessions_dir | path join "token")

    job spawn {
        try {
            do { ^$holder --state-dir $state_dir --shell /bin/sh --cols 80 --rows 24 }
            | save --force ($state_dir | path join "holder.out")
        } catch { |why| null }
    }

    # The requests an agent makes: hello, what can you do, what is held, a
    # send without the token, and a send with it.
    let requests = [
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"multiplexer_sessions\",\"arguments\":{}}}"
        $"{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"multiplexer_send\",\"arguments\":{\"session\":\"($session)\",\"data\":\"echo sent-by-the-agent\\n\"}}}"
        $"{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"multiplexer_send\",\"arguments\":{\"session\":\"($session)\",\"data\":\"echo sent-with-the-token\\n\",\"confirm\":\"the-human-token\"}}}"
        $"{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"multiplexer_records\",\"arguments\":{\"session\":\"($session)\",\"since\":0}}}"
    ] | str join (char newline)

    let said = ($requests | ^$server --sessions-dir $sessions_dir | complete)

    let hello = (answer-of $said.stdout 1)
    let version = ($hello | get -o result | get -o protocolVersion | default "")
    check "the server says hello" ($version != "") $"protocol=($version)"

    let listed = (answer-of $said.stdout 2)
    let names = ($listed | get -o result | get -o tools | each {|t| $t | get name } | str join ",")
    check "the server lists its tools" ($names | str contains "multiplexer_sessions") $"tools=($names)"

    let sessions = (answer-of $said.stdout 3)
    let envelope = (text-of $sessions | from json)
    let held = ($envelope | get -o data | get -o sessions | length)
    check "the agent sees the session" ($held > 0) $"sessions=($held)"

    let refused = (answer-of $said.stdout 4)
    let refusal_text = (text-of $refused | from json)
    let refusal_ok = ($refusal_text | get -o ok)
    let refusal_rule = ($refusal_text | get -o refusal | get -o rule | default "")
    check "a send without the token is refused" ($refusal_ok == false) $"rule=($refusal_rule)"

    let sent = (answer-of $said.stdout 5)
    let sent_text = (text-of $sent | from json)
    let sent_ok = ($sent_text | get -o ok)
    let sent_why = ($sent_text | get -o refusal | get -o message | default "")
    check "a send with the token runs" ($sent_ok == true) $"ok=($sent_ok) why=($sent_why)"

    let records = (answer-of $said.stdout 6)
    let records_text = (text-of $records | from json)
    let log = ($records_text | get -o data | get -o records | default [])
    let said_hello = ($log | where {|r| $r | get -o outputs | get -o text | default "" | str contains "sent-with-the-token" } | length)
    check "the agent reads what the shell said" ($said_hello > 0) $"hits=($said_hello)"

    # the holder goes away with the probe
    let pid_file = ($state_dir | path join "holder.pid")
    if ($pid_file | path exists) {
        let pid = (open --raw $pid_file | str trim)
        do -i { ^kill -TERM $pid }
        print $"PROBE: the holder ($pid) was stopped with the probe"
    }
    rm -rf $sessions_dir
}
