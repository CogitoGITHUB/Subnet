#!/usr/bin/env nu
# One job: the kit conformance check — the six proofs the kit format names,
# proved here for the multiplexer. Registered in gate/INDEX.org; lands with
# TODO item 11.
#
# The multiplexer has no other kit-check stage: these six proofs are the
# program's own conformance proof, and each one runs the thing it proves and
# reads the answer back. They are the editor's six, in the same order:
#   1. the one envelope honored — the MCP's answer carries every field and
#      names this program
#   2. frozen exit codes, with a refusal that names its rule
#   3. MCP gating: a change needs the human's token, the server checks the
#      token itself, and it re-checks the declaration before it runs a tool
#   4. the skill's examples executed by this check
#   5. the plugin proven read-only
#   6. the feed flushed and the wait door held
#
# A proof that fails names what failed; a proof that would check nothing says
# NOTHING-TO-CHECK and is never a pass. The exit code is the answer: 0 when
# the six hold, 1 when one does not, 3 when the built programs are not there
# (nothing can be proved, and the check says so instead of guessing).
#
# The fixture: the check starts one real session (a holder with one shell
# pane) in a scratch directory, because four of the six proofs are about what
# a session does. The scratch directory is removed at the end.

use ./env.nu *

# scratch_name is the directory under TMPDIR where the proofs put their files.
const SCRATCH_NAME = "aiu-mux-kit-check"

# token is the human's token the check uses to prove the gate. The engine
# checks it against its own copy, so the check writes that copy itself.
const TOKEN = "kit-check-token"

# program_name is the program every envelope must name.
const PROGRAM_NAME = "aiu-multiplexer"

# rule_gate is the rule a change is refused by, as the server names it.
const RULE_GATE = "rule 07"

# target_dirs answers the directories the built programs are looked for, in
# the order they are looked for: the cargo target in the environment, then the
# one where the check runs, then the package's own, then this phone's.
def target_dirs [] {
    let from_env = (if ("CARGO_TARGET_DIR" in $env) {
        [$env.CARGO_TARGET_DIR | path join "debug"]
    } else {
        []
    })
    let here = ((pwd) | path join "target" | path join "debug")
    let package_target = ($package_dir | path join "target" | path join "debug")
    $from_env | append $here | append $package_target | append "/tmp/opencode/mux-target/debug"
}

# binary_in answers the built program of that name, or null when no directory
# holds it: the check never guesses a path.
def binary_in [name dirs] {
    let hits = ($dirs | each {|d| $d | path join $name } | where {|p| $p | path exists })
    if ($hits | is-empty) { null } else { $hits | first }
}

# tried answers the problems of one proof, and turns a proof that raised into
# a problem of its own: a broken proof fails by name instead of stopping the
# check before the other five are looked at.
def tried [work: closure] {
    try { do $work } catch {|e| [$"the proof could not finish: ($e.msg)"] }
}

# call_request answers one MCP request line for a tool call.
def call_request [id name arguments] {
    ('{"jsonrpc":"2.0","id":' + ($id | into string)
        + ',"method":"tools/call","params":{"name":"' + $name
        + '","arguments":' + $arguments + "}}")
}

# run_mcp asks the server one request and answers the exit code, the whole
# JSON-RPC answer, and the envelope carried inside it (null when the answer
# does not carry one). The environment's token is emptied, so the engine's own
# copy in the sessions directory is the only token it has: that is the token
# the check proves.
def run_mcp [bin sessions request] {
    let run = (with-env {AIU_MULTIPLEXER_TOKEN: ""} {
        $request | ^$bin --sessions-dir $sessions | complete
    })
    let text = (try {
        $run.stdout | from json | get result | get content | get 0 | get text
    } catch { null })
    let one = (if ($text == null) {
        null
    } else {
        try { $text | from json } catch { null }
    })
    {code: $run.exit_code, envelope: $one, err: $run.stderr}
}

# start_session starts the fixture: one holder in the background, one shell
# pane, its log and its socket in the scratch directory. It answers what it
# saw, and whether a record was readable in the log while the holder still ran
# — which is the feed's half of proof six, taken at the moment it happened.
def start_session [holder scratch sessions] {
    let dir = ($sessions | path join "kit")
    mkdir $dir
    let out = ($scratch | path join "holder.out")
    let err = ($scratch | path join "holder.err")
    let log = ($dir | path join "events.log")
    let command = 'o=$1; e=$2; shift 2; "$@" >"$o" 2>"$e" & echo $!'
    let started = (^bash -c $command kit-check $out $err
        $holder --state-dir $dir --shell /bin/sh | complete)
    let pid = ($started.stdout | str trim)
    let socket = ($dir | path join "holder.sock")
    let readable = (wait_log $log 60)
    let ready = (wait_file $socket 60)
    let alive = (^bash -c 'kill -0 "$1" 2>/dev/null' kit-check $pid | complete)
    let held = (($started.exit_code == 0) and $readable)
    let said = (if ($err | path exists) { open --raw $err | str trim } else { "" })
    let why = (if $held { "" } else { $"the holder did not hold the session: ($said)" })
    {pid: $pid, log: $log, dir: $dir, socket: $socket, held: $held
        readable: $readable, ready: $ready
        alive: ($alive.exit_code == 0), why: $why}
}

# wait_log waits, a turn at a time, until the log file holds a record: the
# holder writes its first record before it serves, so a record that shows
# while the holder runs is a record that was flushed. The wait is a loop and
# not a recursion: a deep recursion would hit the parser's limit.
def wait_log [log left] {
    mut here = false
    mut tries = $left
    while $here == false and $tries > 0 {
        if (($log | path exists) and (((open --raw $log) | str length) > 0)) {
            $here = true
        } else {
            sleep 50ms
            $tries = $tries - 1
        }
    }
    $here
}

# wait_file waits until the file is there: the holder's socket is the sign
# that the session is held, and the wait ends on the filesystem event that
# creates it.
def wait_file [path left] {
    mut here = false
    mut tries = $left
    while $here == false and $tries > 0 {
        if ($path | path exists) {
            $here = true
        } else {
            sleep 50ms
            $tries = $tries - 1
        }
    }
    $here
}

# wait_text waits until the log holds a piece of text, so a proof can read
# what the session did without guessing how long the shell takes.
def wait_text [log text left] {
    mut here = false
    mut tries = $left
    while $here == false and $tries > 0 {
        if (($log | path exists) and ((open --raw $log) | str contains $text)) {
            $here = true
        } else {
            sleep 50ms
            $tries = $tries - 1
        }
    }
    $here
}

# proof_envelope proves the one envelope: the MCP's answer to a read carries
# program, version, kind, ok, data, refusal and events, names this program,
# and names the session the check holds.
def proof_envelope [bin sessions] {
    let run = (run_mcp $bin $sessions (call_request 1 "multiplexer_sessions" "{}"))
    let one = $run.envelope
    if ($one == null) { return ["the MCP did not answer in the one envelope"] }
    let fields = ["program" "version" "kind" "ok" "data" "refusal" "events"]
    let names = ($one | columns)
    let missing = ($fields
        | where {|f| ($names | where {|n| $n == $f } | is-empty) }
        | each {|f| $"the envelope has no ($f) field" })
    let wrong = (if ($one.program == $PROGRAM_NAME) {
        []
    } else {
        ["the envelope names another program"]
    })
    let silent = (if ($one.ok == true) {
        [] } else { ["the envelope says the read did not answer"] })
    let seen = (try { $one.data.sessions | length } catch { 0 })
    let unnamed = (if ($seen > 0) {
        []
    } else {
        ["the envelope names no session, and the check holds one"]
    })
    $missing | append $wrong | append $silent | append $unnamed
}

# proof_exit_codes proves the frozen codes: 0 when the program answers, 2 when
# it refuses and names the rule it refused by, 3 when it cannot run at all.
def proof_exit_codes [bin sessions] {
    let help = (^$bin --help | complete)
    let answered = (if ($help.exit_code == 0) {
        []
    } else {
        [$"the usage left code ($help.exit_code), and the answer code is 0"]
    })
    let refused = (run_mcp $bin $sessions
        (call_request 2 "multiplexer_send" '{"session":"kit","data":"true\n"}'))
    let rule = (try { $refused.envelope.refusal.rule } catch { "" })
    let by_code = (if ($refused.code == 2) {
        []
    } else {
        [$"the refusal left code ($refused.code), and the refusal code is 2"]
    })
    let named = (if (($rule | str length) > 0) {
        [] } else { ["the refusal names no rule"] })
    let by_rule = (if ($rule | str starts-with $RULE_GATE) {
        []
    } else {
        [$"the refusal names ($rule), and a change is refused by ($RULE_GATE)"]
    })
    let bare = (^$bin | complete)
    let cannot = (if ($bare.exit_code == 3) {
        []
    } else {
        [$"the server with no option left code ($bare.exit_code), and the cannot-run code is 3"]
    })
    $answered | append $by_code | append $named | append $by_rule | append $cannot
}

# proof_gating proves the gating: a change with no token is refused, a change
# with a token that is not the engine's is refused, a change with the engine's
# own token runs and the session does what it was told, and the declaration
# and the gate agree about which tools need the token — which is the check the
# server runs before it runs any tool.
def proof_gating [bin sessions held] {
    if ($held.held == false) {
        return [$"the session this proof needs did not start: ($held.why)"]
    }
    let data = '{"session":"kit","data":"echo kit-check-marker\n"'
    let without = (run_mcp $bin $sessions (call_request 3 "multiplexer_send" ($data + "}")))
    let wrong_args = ($data + ',"confirm":"not-the-token"}')
    let wrong = (run_mcp $bin $sessions (call_request 4 "multiplexer_send" $wrong_args))
    let right_args = ($data + ',"confirm":"' + $TOKEN + '"}')
    let right = (run_mcp $bin $sessions (call_request 5 "multiplexer_send" $right_args))
    let no_rule = (if (try { ($without.envelope.refusal.rule | str length) > 0 } catch { false }) {
        []
    } else {
        ["a change with no token was answered without a rule, so it was not refused by name"]
    })
    let not_refused = (if (try { $without.envelope.ok } catch { true }) {
        ["a change with no token was not refused"]
    } else {
        []
    })
    let held_wrong = (if (try { $wrong.envelope.ok } catch { true }) {
        ["a change with the wrong token was not refused"]
    } else {
        []
    })
    let ran = (if (try { $right.envelope.ok } catch { false }) {
        []
    } else {
        ["a change with the engine's own token was refused anyway"]
    })
    let did = (if (wait_text $held.log "kit-check-marker" 60) {
        []
    } else {
        ["the token let the change through, but the session never did what it was told"]
    })
    let listed = (with-env {AIU_MULTIPLEXER_TOKEN: ""} {
        '{"jsonrpc":"2.0","id":6,"method":"tools/list"}'
        | ^$bin --sessions-dir $sessions | complete
    })
    let tools = (try {
        $listed.stdout | from json | get result | get tools
    } catch { [] })
    let declared = (try {
        open --raw ($package_src | path join "agents" | path join "capabilities.json")
        | from json
    } catch { [] })
    let changes = ($declared | where {|t| $t.mutates == true } | each {|t| $t.name })
    let disagree = (if ($tools | is-empty) {
        ["the server listed no tool, so the declaration could not be compared"]
    } else {
        $tools | each {|t|
            let must = ($t.inputSchema.required
                | where {|r| $r == "confirm" } | is-empty)
            let declared_change = ($changes | where {|n| $n == $t.name } | is-empty)
            if ($must == $declared_change) { null } else {
                $"the tool ($t.name) and the declaration disagree about the token"
            }
        } | where {|p| $p != null }
    })
    let source = (open --raw ($package_src | path join "agents" | path join "mcp.rs"))
    let recheck = (if ($source | str contains "declared_agrees(&cap)") {
        []
    } else {
        ["the server does not re-check the declaration before it runs a tool"]
    })
    $no_rule | append $not_refused | append $held_wrong | append $ran
    | append $did | append $disagree | append $recheck
}

# proof_skill proves the skill's examples: every line of the skill that names
# the program is a command, and it is run here from the project directory with
# the program's name mapped to the program the check found. The example must
# answer: a command that fails is a fault of the skill, and it is named.
def proof_skill [bin skill] {
    let lines = (open --raw $skill | lines
        | each {|l| $l | str trim }
        | where {|l| ($l | str starts-with "mux-mcp") and (($l | str length) > 0) })
    if ($lines | is-empty) {
        return ["the skill holds no example to run, so nothing was executed"]
    }
    $lines | each {|line|
        let command = ($line | str replace --all "mux-mcp" $bin)
        let run = (^bash -c 'cd "$1" || exit 9; eval "$2"' kit-check $project_root $command
            | complete)
        if (($run.exit_code == 0) and (($run.stdout | str length) > 0)) {
            null
        } else {
            $"the example did not answer: ($line) — code ($run.exit_code)"
        }
    } | where {|p| $p != null }
}

# proof_plugin proves the watcher is read-only: its source holds no write
# call, and running it on a real log prints the records and leaves the file
# exactly as it was.
def proof_plugin [plugin log scratch] {
    let source = (open --raw $plugin)
    let calls = ["writeFileSync" "writeFile" "appendFile" "appendFileSync"
        "createWriteStream" "unlink" "unlinkSync" "rmSync" "mkdirSync"
        "renameSync" "copyFileSync" "truncateSync" "chmodSync" "openSync"
        "linkSync" "symlinkSync"]
    let writers = ($calls
        | where {|c| $source | str contains $c }
        | each {|c| $"the plugin holds a write call: ($c)" })
    let watched = ($scratch | path join "watched.log")
    if ($log | path exists) { cp $log $watched } else {
        "" | save --force $watched
    }
    let before = (open --raw $watched)
    let run = (^node $plugin $watched | complete)
    let after = (open --raw $watched)
    let ran = (if ($run.exit_code == 0) {
        [] } else { ["the plugin did not run"] })
    let printed = (if (($run.stdout | str length) > 0) {
        [] } else { ["the plugin printed no record"] })
    let read_start = (if ($run.stdout | str contains "start") {
        []
    } else {
        ["the plugin printed no start record, so it did not read the log"]
    })
    let intact = (if ($before == $after) {
        [] } else { ["the plugin changed the file it watches"] })
    $writers | append $ran | append $printed | append $read_start | append $intact
}

# proof_feed_and_door proves the last two halves: a record the holder wrote was
# readable in the log while the holder still ran and the log holds whole
# records, and the wait door refuses a blank reason and announces a wait that
# has one. The door is proved by running Racket on the module, not by reading
# it.
def proof_feed_and_door [held] {
    let raw = (if ($held.log | path exists) {
        open --raw $held.log
    } else {
        ""
    })
    let records = ($raw | lines | where {|l| ($l | str trim | str length) > 0 })
    let whole = (if ($raw | str ends-with (char newline)) {
        []
    } else {
        ["the feed's last record is not whole: it was not flushed"]
    })
    let some = (if (($records | length) > 0) {
        [] } else { ["the feed holds no record"] })
    let readable = (if ($held.readable) {
        []
    } else {
        ["no record was readable in the log while the holder ran"]
    })
    let holding = (if ($held.alive) {
        []
    } else {
        ["the holder was gone when the feed was read, so the flush is unproved"]
    })
    let shaped = ($records | each {|r|
        try { $r | from json | ignore; null } catch {
            "the feed holds a line that is not a record"
        }
    } | where {|p| $p != null })
    let racket = (racket_bin)
    let door = ($package_src | path join "narration" | path join "wait-door.rkt")
    let voice = ($package_src | path join "narration" | path join "narration.rkt")
    let opener = '(require (file "' + $door + '") (file "' + $voice + '")) '
    let opening = '(define r (open-run "kit-check")) '
    let blank_wait = '(wait-for r "the feed" #:why "" #:how "the check") (void)'
    let blank = (^$racket -e ($opener + $opening + $blank_wait) | complete)
    let refused = (if ($blank.exit_code != 0) {
        []
    } else {
        ["the wait door held a wait with no reason"]
    })
    let said = (if ($blank.stderr | str contains "a wait reason was blank") {
        []
    } else {
        ["the refused wait does not say why it was refused"]
    })
    let why = "the check needs a wait to prove the door"
    let kept_wait = '(wait-for r "the feed" #:why "' + $why + '" #:how "the check") (void)'
    let kept = (^$racket -e ($opener + $opening + $kept_wait) | complete)
    let ran = (if ($kept.exit_code == 0) {
        [] } else { ["the wait with a reason did not run"] })
    let announced = (if ($kept.stdout | str contains "WAIT") {
        []
    } else {
        ["the wait did not announce itself before it blocked"]
    })
    let with_why = (if ($kept.stdout | str contains $why) {
        [] } else { ["the wait's line carries no reason"] })
    $whole | append $some | append $readable | append $holding | append $shaped
    | append $refused | append $said | append $ran | append $announced | append $with_why
}

# scratch_dir answers where the proofs put their files: under TMPDIR.
def scratch_dir [] {
    let base = (if ("TMPDIR" in $env) { $env.TMPDIR } else { "/tmp" })
    $base | path join ($SCRATCH_NAME + "-" + (random uuid))
}

# main runs the six proofs, prints one line for each, and answers with the
# verdict: green when the six hold, red when one of them does not, and
# cannot-run when the built programs are not there to be proved.
def main [] {
    let scratch = (scratch_dir)
    rm --recursive --force $scratch
    mkdir $scratch
    let dirs = (target_dirs)
    let where = ($dirs | str join ", ")
    let found = (["mux-mcp" "holder"]
        | each {|n| {name: $n, path: (binary_in $n $dirs)} })
    let missing = ($found | where {|f| $f.path == null })
    if (($missing | length) > 0) {
        for f in $missing {
            print $"KIT — MISSING-BINARY ($f.name): not in ($where)"
        }
        print "KIT — the six proofs need the built programs, and nothing was proved"
        print "      CARGO_TARGET_DIR=/tmp/opencode/mux-target cargo build --offline"
        print "kit-check: red, the built programs are not there — NOTHING-TO-CHECK"
        exit 3
    }
    let mcp = (($found | where {|f| $f.name == "mux-mcp" } | first).path)
    let holder = (($found | where {|f| $f.name == "holder" } | first).path)
    let sessions = ($scratch | path join "sessions")
    mkdir $sessions
    $TOKEN | save --force ($sessions | path join "token")
    let skill = ($project_root | path join "ai" | path join "skills"
        | path join "multiplexer" | path join "SKILL.md")
    let plugin = ($project_root | path join "ai" | path join "opencode-plugin"
        | path join "session-watch.js")
    let held = (start_session $holder $scratch $sessions)

    let proofs = [
        {name: "the one envelope"
            what: "the MCP's answer names this program and carries every field"
            problems: (do { print --stderr "KIT: proof 1 (the one envelope) starts"
                (tried {|| proof_envelope $mcp $sessions }) })}
        {name: "the frozen exit codes"
            what: "0 answers, 2 refuses and names the rule, 3 cannot run"
            problems: (do { print --stderr "KIT: proof 2 (the exit codes) starts"
                (tried {|| proof_exit_codes $mcp $sessions }) })}
        {name: "the gating and the re-check"
            what: "the token is the engine's own, and the declaration is re-checked"
            problems: (do { print --stderr "KIT: proof 3 (the gating) starts"
                (tried {|| proof_gating $mcp $sessions $held }) })}
        {name: "the skill's examples"
            what: "every example the skill holds was run and answered"
            problems: (do { print --stderr "KIT: proof 4 (the skill) starts"
                (tried {|| proof_skill $mcp $skill }) })}
        {name: "the read-only plugin"
            what: "no write call, and the file it watches is unchanged"
            problems: (do { print --stderr "KIT: proof 5 (the plugin) starts"
                (tried {|| proof_plugin $plugin $held.log $scratch }) })}
        {name: "the flushed feed and the held door"
            what: "a record showed while the holder ran, and a blank reason was refused"
            problems: (do { print --stderr "KIT: proof 6 (the feed and the door) starts"
                (tried {|| proof_feed_and_door $held }) })}
    ]

    let pid = $held.pid
    ^bash -c 'kill "$1" 2>/dev/null; exit 0' kit-check $pid | complete | ignore
    rm --recursive --force $scratch

    let total = ($proofs | length)
    for at in 0..($total - 1) {
        let one = ($proofs | get $at)
        let n = ($at + 1)
        let problems = ($one.problems)
        if (($problems | length) == 0) {
            let said = $"($n). ($one.name) — OK: ($one.what)"
            print $said
        } else {
            print $"($n). ($one.name) — FAIL"
            for p in $problems {
                print $"   KIT — ($p)"
            }
        }
    }
    let bad = ($proofs | where {|p| ($p.problems | length) > 0 } | length)
    if ($bad == 0) {
        print $"kit-check: green, the six proofs hold, ($total) proofs ran"
        exit 0
    }
    print $"kit-check: red, ($bad) of the ($total) proofs do not hold"
    exit 1
}
