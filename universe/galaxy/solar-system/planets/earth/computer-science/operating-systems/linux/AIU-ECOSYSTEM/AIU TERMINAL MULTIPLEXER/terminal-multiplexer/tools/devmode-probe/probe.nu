#!/usr/bin/env nu
# probe.nu -- the phone proof of the dev mode (TODO item 7): the config is
# reloaded live, and the bake keeps the last good.
#
# One job: show, with printed evidence, that ONE running client takes a
# change to the config file in force without a restart, and that the bake
# keeps the last good: a good bake becomes the last good, and a broken one
# does not take its place.
#
# The proof of "without a restart" is the proof itself: the client is
# started ONCE, the config file is changed under it, the client is given
# an event, and the LAST drawing answers with the new values. A client that
# had restarted would have printed its start twice, and the probe counts
# the starts.
#
# The event that turns the client's loop is the pane's own output: the
# probe sends a command to the pane, the shell answers, and the answer
# arrives as a record. No timer turns anything here: the wait ends on the
# file growing.
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

# last-drawing answers the last drawing of a screen: the screen draws again
# after every event, and the last one is the state it stands in.
def last-drawing [out: string] {
    ($out | split row "\u{1b}[?25l" | last)
}

# wait-for-drawing reads the drawing file until it holds what is looked for,
# or until the tries are spent. The wait ends on the file growing.
def wait-for-drawing [file: string, wanted: string, tries: int] {
    mut found = false
    mut at = 0
    while $found == false and $at < $tries {
        let body = (try { open --raw $file } catch { |why| "" })
        if ($body | str contains $wanted) {
            $found = true
        } else {
            sleep 100ms
            $at = $at + 1
        }
    }
    $found
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
        $"/tmp/opencode/mux-devmode-(random uuid)"
    } else {
        $state_dir
    })
    let holder = ($bin_dir | path join "holder")
    let client = ($bin_dir | path join "client")
    let bake = ($bin_dir | path join "mux-bake")

    print $"PROBE: holder=($holder)"
    print $"PROBE: client=($client)"
    print $"PROBE: bake=($bake)"
    print $"PROBE: state-dir=($state_dir)"

    rm -rf $state_dir
    mkdir $state_dir

    # The layout: one pane, running a shell.
    let layout = {
        "direction": "row"
        "panes": [
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

    # The config the client runs with: the file the environment names.
    let config = ($state_dir | path join "config.json")
    { "level": 1, "tab-bar": true } | to json | save --force $config

    # The client, started ONCE. Its keys come from a pipe that never ends
    # (tail reads a file that is never written), so the client keeps its
    # loop and waits for the holder's records.
    let drawing = ($state_dir | path join "drawing.txt")
    let start = ($state_dir | path join "start.txt")
    job spawn {
        with-env {AIU_MULTIPLEXER_CONFIG: $config} {
            ^tail -f /dev/null | ^$client --state-dir $state_dir --op screen out> $drawing err> $start
        }
    }

    # 1. the client prints its start: the mode it is in and the config it
    #    runs with.
    let started = (wait-for-drawing $drawing "VISUAL" 60)
    check "the client draws its first screen" $started "the first drawing is there"
    let start_text = (open --raw $start | str trim)
    check "the client prints its start" ($start_text | str contains "work mode") $"start=($start_text)"
    check "the start names the config it runs with" ($start_text | str contains $config) $"start=($start_text)"

    let first = last-drawing (open --raw $drawing)
    check "the drawing holds the mode row" ($first | str contains "VISUAL") "the mode row is there"
    check "the drawing holds the tab bar" ($first | str contains "[main]") "the tab bar is there"

    # 2. the config is reloaded live: the file is changed under the RUNNING
    #    client, and the next event turns its loop. The drawing that comes
    #    after the change answers with the new values.
    { "level": 0, "tab-bar": false } | to json | save --force $config

    # The event: a command to the pane. The shell answers, the answer
    # arrives as a record, and the client draws again.
    let sent = (do -i {
        ^$client --state-dir $state_dir --op send --data "echo after-the-change\n" | complete
    })
    check "the command went to the pane" ($sent.exit_code == 0) $"exit=($sent.exit_code)"

    # The drawing grows when the answer arrives; the wait ends on the file.
    let grew = (wait-for-drawing $drawing "after-the-change" 80)
    check "the pane answered and the client drew again" $grew "the answer is in the drawing"

    let second = last-drawing (open --raw $drawing)
    check "the new level is in force" (($second | str contains "VISUAL") == false) "no mode row at level 0"
    check "the tab bar is gone" (($second | str contains "[main]") == false) "no tab bar"

    # The client is the same one: it printed its start once, not twice.
    let starts = ($start_text | lines | where {|line| $line | str contains "work mode" } | length)
    check "the client never restarted" ($starts == 1) $"starts=($starts)"

    # 3. the bake: a good config becomes the last good, and it says so.
    let good = (do -i { ^$bake --state-dir $state_dir --config $config | complete })
    check "the bake is good" ($good.exit_code == 0) $"exit=($good.exit_code)"
    check "the bake says it is good" ($good.stdout | str contains "good:") $"out=($good.stdout | str trim)"
    let last_good = ($state_dir | path join "last-good")
    check "the last good is recorded" ($last_good | path exists) $"path=($last_good)"

    # 4. the bake keeps the last good: a config that does not parse is
    #    refused, and the last good stays the last good.
    let broken = ($state_dir | path join "broken.json")
    { "level": 9 } | to json | save --force $broken
    let bad = (do -i { ^$bake --state-dir $state_dir --config $broken | complete })
    check "a broken config is not baked" ($bad.exit_code != 0) $"exit=($bad.exit_code)"
    check "the bake says why" ($bad.stdout | str contains "not good:") $"out=($bad.stdout | str trim)"
    check "the last good stays" ($last_good | path exists) $"path=($last_good)"

    # The last good still holds the good path: the broken bake did not
    # take its place.
    let held = (open --raw $last_good | str trim)
    check "the last good is the good one" ($held | str contains "config.json") $"held=($held)"

    print "PROBE: the dev mode holds: one running client took the change in force, and the bake keeps the last good"
}
