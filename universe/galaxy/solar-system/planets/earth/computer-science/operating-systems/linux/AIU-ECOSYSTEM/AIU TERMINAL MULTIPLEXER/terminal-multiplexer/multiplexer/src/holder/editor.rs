// One job: the editor's own answer — the editor's own server asked, and its
// own words given back.
//
// The multiplexer asks the editor through the editor's OWN surface: the MCP
// server the editor ships, over the editor's own wire (one JSON-RPC object
// per line, one answer per line). The ask is read-only: the capability asked
// for changes nothing, and the editor's own engine re-checks that before it
// runs anything (rule 07).
//
// The command that starts the editor's server is given at runtime, never
// written here: this file names no program of the editor, so the two
// languages never meet in this file (D-028). Without that command there is
// nothing to ask, and the ask is refused BY NAME.

use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Command, Stdio};
use std::time::Instant;

use serde_json::{json, Value};

/// Answer is what the editor said: whether it could answer, and its own
/// words.
pub struct Answer {
    pub ok: bool,
    pub data: Value,
}

/// ask asks the editor what it owns, through the editor's own server.
///
/// The command is the program and what it runs: the first word is the
/// program, the rest are its arguments. The capability is the editor's own
/// name for the read it does; the editor refuses a capability it does not
/// have, and the refusal comes back as the editor's own words.
///
/// The ask takes as long as the editor's server takes to start, and that is
/// said in the answer: the caller never waits without knowing why.
pub fn ask(command: &[String], capability: &str) -> Answer {
    if command.is_empty() {
        return Answer {
            ok: false,
            data: json!({
                "why": "there is no command for the editor's server: give one with --editor-mcp-arg"
            }),
        };
    }
    let started = Instant::now();
    let mut child = match Command::new(&command[0])
        .args(&command[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(why) => {
            return Answer {
                ok: false,
                data: json!({
                    "why": format!("the editor's server did not start: {}", why),
                    "command": command,
                }),
            }
        }
    };
    // The two requests: the handshake, and the read itself. One line each,
    // the way the editor's server speaks.
    {
        let mut stdin = match child.stdin.take() {
            Some(stdin) => stdin,
            None => {
                return Answer {
                    ok: false,
                    data: json!({ "why": "the editor's server has no input to read" }),
                }
            }
        };
        let handshake = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": { "name": "multiplexer", "version": "1" }
            }
        });
        let call = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": { "name": capability, "arguments": { "args": [] } }
        });
        if let Err(why) = writeln!(stdin, "{}", handshake)
            .and_then(|_| writeln!(stdin, "{}", call))
            .and_then(|_| stdin.flush())
        {
            return Answer {
                ok: false,
                data: json!({ "why": format!("the editor's server was not asked: {}", why) }),
            };
        }
    }
    // The answers: one line each, in the order the requests were sent.
    let mut lines: Vec<String> = Vec::new();
    if let Some(stdout) = child.stdout.take() {
        let mut reader = BufReader::new(stdout);
        let mut line = String::new();
        while lines.len() < 2 {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => {
                    let text = line.trim().to_string();
                    if !text.is_empty() {
                        lines.push(text);
                    }
                }
                Err(why) => {
                    return Answer {
                        ok: false,
                        data: json!({
                            "why": format!("the editor's answer was not read: {}", why)
                        }),
                    }
                }
            }
        }
    }
    // The editor's server is ended here: the holder never waits on a child
    // that will not leave, and the child is not left behind either.
    let _ = child.kill();
    let _ = child.wait();
    let elapsed = started.elapsed().as_millis();
    let answer = match lines.get(1) {
        Some(line) => line.clone(),
        None => {
            let mut why = format!(
                "the editor's server said nothing: it was asked and it did not answer ({} ms)",
                elapsed
            );
            if let Some(stderr) = child.stderr.take() {
                let mut text = String::new();
                let _ = BufReader::new(stderr).read_to_string(&mut text);
                if !text.trim().is_empty() {
                    why = format!("{}: {}", why, text.trim());
                }
            }
            return Answer {
                ok: false,
                data: json!({ "why": why, "command": command }),
            };
        }
    };
    let parsed: Value = match serde_json::from_str(&answer) {
        Ok(value) => value,
        Err(why) => {
            return Answer {
                ok: false,
                data: json!({
                    "why": format!("the editor's answer is not one record: {}", why),
                    "answer": answer,
                }),
            }
        }
    };
    // The editor's own words: the envelope the tool answered with, and the
    // text inside it.
    let words = parsed
        .get("result")
        .and_then(|result| result.get("content"))
        .and_then(|content| content.as_array())
        .and_then(|content| content.first())
        .and_then(|first| first.get("text"))
        .and_then(|text| text.as_str())
        .unwrap_or("");
    let envelope: Value = match serde_json::from_str(words) {
        Ok(value) => value,
        Err(_) => json!({}),
    };
    let text = envelope
        .get("data")
        .and_then(|data| data.get("text"))
        .and_then(|text| text.as_str())
        .unwrap_or(words)
        .to_string();
    // A refusal is a refusal that says something: an empty refusal is no
    // refusal at all, and the editor's own envelope carries it empty when
    // the tool ran.
    let refused = match envelope.get("refusal") {
        None | Some(Value::Null) => false,
        Some(Value::Array(list)) => !list.is_empty(),
        Some(Value::Object(map)) => !map.is_empty(),
        Some(Value::String(text)) => !text.is_empty(),
        Some(_) => true,
    };
    Answer {
        ok: !refused && !text.is_empty(),
        data: json!({
            "capability": capability,
            "text": text,
            "took-ms": elapsed,
        }),
    }
}
