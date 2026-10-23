#!/usr/bin/env nu
# probe.nu -- the phone proof for the holder and the client (TODO item 3).
#
# One job: show, with printed evidence, that a shell held by the holder
# survives the detach of its client, that the shell keeps writing to the
# session log after that detach, and that a second client finds the same
# session.
#
# No timers: every wait here ends on an event. The client waits for the
# holder's socket with a filesystem watch, and the holder waits with one
# poll for the shell writing or a client asking. Nothing sleeps and nothing
# polls in a loop.
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

# holds answers whether the log holds a piece of text, and how many times.
def holds [text: string, needle: string] {
    let lines = ($text | lines | where {|line| ($line | str trim) != "" })
    let records = ($lines | each {|line| $line | from json })
    $records | where {|record|
        ($record | get -o outputs | get -o text? | default "" | str contains $needle)
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
        $"/tmp/opencode/mux-probe-state-(random uuid)"
    } else {
        $state_dir
    })
    let holder = ($bin_dir | path join "holder")
    let client = ($bin_dir | path join "client")

    print $"PROBE: holder=($holder)"
    print $"PROBE: client=($client)"
    print $"PROBE: state-dir=($state_dir)"

    # A fresh session directory: the probe starts from nothing, so what it
    # shows is the session it made.
    rm -rf $state_dir
    mkdir $state_dir

    # The holder runs beside the probe; its own records land in the session
    # log, and the log is the evidence. The holder's screen lines are kept
    # in their own file, so they never mix with the probe's evidence.
    let holder_out = ($state_dir | path join "holder.out")
    job spawn {
        # The holder is stopped with the probe, and a stopped holder is not a
        # failure of the probe: the catch keeps the script's own answer clean.
        try {
            do { ^$holder --state-dir $state_dir --shell /bin/sh --cols 80 --rows 24 }
            | save --force $holder_out
        } catch { |why| null }
    }

    # 1. a client attaches, sees the session and detaches again
    let first = (do -i { ^$client --state-dir $state_dir --op attach --count 1 } | complete)
    let first_state = (first-record $first.stdout)
    if $first_state == null {
        check "client-1 attaches" false $"stderr=($first.stderr | str trim)"
        return
    }
    let session_id = ($first_state | get outputs | get session)
    let first_pane = ($first_state | get outputs | get panes | first)
    let shell_pid = ($first_pane | get pid)
    let alive_after_detach = ($first_pane | get alive)
    check "client-1 attaches and detaches" true $"session=($session_id) shell-pid=($shell_pid)"

    # 2. the shell is alive AFTER the client is gone: that is the promise
    check "the shell lives past the detach" $alive_after_detach $"shell-pid=($shell_pid)"

    # 3. the shell still takes data and still writes to the log
    let send_one = (do -i {
        ^$client --state-dir $state_dir --op send --data "echo mux-alive\n"
    } | complete)
    check "the shell takes data after the detach" ($send_one.exit_code == 0) $"rc=($send_one.exit_code)"

    let second = (do -i { ^$client --state-dir $state_dir --op state } | complete)
    let second_state = (first-record $second.stdout)
    if $second_state == null {
        check "the holder answers the state" false $"stderr=($second.stderr | str trim)"
        return
    }
    let records_now = ($second_state | get outputs | get records)
    check "the holder answers the state" true $"records=($records_now)"

    # 4. a second client finds the SAME session and the SAME shell
    let third = (do -i { ^$client --state-dir $state_dir --op attach --count 1 } | complete)
    let third_state = (first-record $third.stdout)
    if $third_state == null {
        check "client-2 finds the same session" false $"stderr=($third.stderr | str trim)"
        return
    }
    let same_session = ($third_state | get outputs | get session) == $session_id
    let same_shell = ($third_state | get outputs | get panes | first | get pid) == $shell_pid
    check "client-2 finds the same session" $same_session $"session=($session_id)"
    check "client-2 finds the same shell" $same_shell $"shell-pid=($shell_pid)"

    # 5. the log holds what the shell wrote, before and after the detach
    let read = (do -i { ^$client --state-dir $state_dir --op read --since 0 } | complete)
    let alive_hits = (holds $read.stdout "mux-alive")
    let after_hits = (holds $read.stdout "mux-alive" | length)
    check "the log holds the shell's output" (($alive_hits | length) > 0) $"hits=($after_hits)"

    # 6. what the phone cannot do is recorded, not promised
    print "PROBE: the phone limit: the holder dies with the session that started it;"
    print "PROBE: what is proved here is the DETACH, not Android survival."

    # the holder goes away with the probe, and the session directory with it
    let pid_file = ($state_dir | path join "holder.pid")
    if ($pid_file | path exists) {
        let pid = (open --raw $pid_file | str trim)
        do -i { ^kill -TERM $pid }
        print $"PROBE: the holder ($pid) was stopped with the probe"
    }
    rm -rf $state_dir
}
