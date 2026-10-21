// One job: the agent's door into the multiplexer — an MCP server over stdio.
//
// The server speaks JSON-RPC 2.0 over the standard input and the standard
// output: one request per line, one answer per line. It answers with the
// one envelope, so an agent reads this server and the client the same way.
//
// Read is free: a read tool runs without a human. A change needs the human's
// token, and the server checks the token itself — the caller's word is not
// taken for what a tool does (rule 07). The declaration of the capabilities
// is data, and the server reads the gate from it before it runs anything.
//
// The exit codes are frozen: 0 when every request was answered, 2 when a
// request was refused, 3 when the server could not answer at all.

#[path = "../holder/wire.rs"] mod wire;
mod envelope;
mod tools;

use envelope::Answer;
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::path::PathBuf;

/// protocol-version is the MCP protocol the server speaks.
const PROTOCOL_VERSION: &str = "2024-11-05";

/// rule-gate is the rule a change is gated by, named in the refusal.
const RULE_GATE: &str = "rule 07: read is free, a change needs the human's token";

/// rule-declaration is the rule a lying declaration is refused by.
const RULE_DECLARATION: &str =
    "rule 07: the declaration and the security predicate must agree";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let sessions_dir = match sessions_dir(&args) {
        Ok(found) => found,
        Err(why) => {
            eprintln!("mux-mcp: {}", why);
            std::process::exit(envelope::EXIT_CANNOT_RUN);
        }
    };
    std::process::exit(serve(&sessions_dir));
}

/// sessions_dir answers the directory that holds the sessions. It is an
/// argument: no environment variable decides where the sessions are.
fn sessions_dir(args: &[String]) -> Result<PathBuf, String> {
    let at = 0;
    while at < args.len() {
        match args[at].as_str() {
            "--sessions-dir" => {
                let value = args
                    .get(at + 1)
                    .cloned()
                    .ok_or("--sessions-dir needs a value")?;
                return Ok(PathBuf::from(value));
            }
            "--help" => {
                println!("mux-mcp --sessions-dir DIR");
                std::process::exit(envelope::EXIT_OK);
            }
            other => return Err(format!("{} is not an option this server knows", other)),
        }
    }
    Err("the server needs --sessions-dir".to_string())
}

/// serve answers every request on the standard input, and says what happened
/// with its exit code.
fn serve(sessions_dir: &PathBuf) -> i32 {
    let stdin = std::io::stdin();
    let mut reader = stdin.lock();
    let mut refused = false;
    let mut line = String::new();
    loop {
        line.clear();
        let got = match reader.read_line(&mut line) {
            Ok(count) => count,
            Err(_) => return envelope::EXIT_CANNOT_RUN,
        };
        if got == 0 {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let request: Value = match serde_json::from_str(trimmed) {
            Ok(value) => value,
            Err(why) => {
                let answer = json!({
                    "jsonrpc": "2.0",
                    "id": Value::Null,
                    "error": { "code": -32700, "message": format!("the request is not JSON: {}", why) }
                });
                if write_answer(&answer).is_err() {
                    return envelope::EXIT_CANNOT_RUN;
                }
                continue;
            }
        };
        let mut is_refusal = false;
        match handle(&request, sessions_dir) {
            Some(answer) => {
                if answer.get("result").is_some() {
                    if let Some(text) = answer
                        .get("result")
                        .and_then(|r| r.get("content"))
                        .and_then(|c| c.get(0))
                        .and_then(|c| c.get("text"))
                        .and_then(|t| t.as_str())
                    {
                        if text.contains("\"ok\":false") {
                            is_refusal = true;
                        }
                    }
                }
                if write_answer(&answer).is_err() {
                    return envelope::EXIT_CANNOT_RUN;
                }
            }
            None => {}
        }
        if is_refusal {
            refused = true;
        }
    }
    if refused {
        envelope::EXIT_REFUSAL
    } else {
        envelope::EXIT_OK
    }
}

/// handle answers one request, or nothing when the request is a
/// notification: a notification has no id and expects no answer.
fn handle(request: &Value, sessions_dir: &PathBuf) -> Option<Value> {
    let id = request.get("id").cloned();
    let method = request
        .get("method")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string();

    if id.is_none() {
        return None;
    }
    let id = id.unwrap();

    match method.as_str() {
        "initialize" => Some(ok(id, json!({
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": { "tools": {} },
            "serverInfo": { "name": envelope::PROGRAM, "version": envelope::VERSION }
        }))),
        "ping" => Some(ok(id, json!({}))),
        "tools/list" => {
            let mut list: Vec<Value> = Vec::new();
            for cap in tools::capabilities() {
                list.push(json!({
                    "name": cap.name,
                    "description": cap.description,
                    "inputSchema": tools::schema(&cap)
                }));
            }
            Some(ok(id, json!({ "tools": Value::Array(list) })))
        }
        "tools/call" => {
            let params = request.get("params").cloned().unwrap_or(json!({}));
            let name = params
                .get("name")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            let arguments = params
                .get("arguments")
                .cloned()
                .unwrap_or(json!({}));
            Some(call(id, &name, &arguments, sessions_dir))
        }
        other => Some(error(id, -32601, format!("there is no method named {}", other))),
    }
}

/// call runs one tool and answers the MCP result: the envelope as the text,
/// and whether it was a refusal.
fn call(id: Value, name: &str, arguments: &Value, sessions_dir: &PathBuf) -> Value {
    let cap = match tools::of(name) {
        Some(found) => found,
        None => return error(id, -32602, format!("there is no tool named {}", name)),
    };
    if cap.mutates && !token_given(arguments, sessions_dir) {
        let refused = Answer::refused(
            "tool",
            RULE_GATE,
            &format!(
                "{} changes what a session does, so it needs the human's token, and it was refused",
                name
            ),
        );
        return result(id, refused.line(), true);
    }
    if !declared_agrees(&cap) {
        let refused = Answer::refused(
            "tool",
            RULE_DECLARATION,
            &format!(
                "the declaration and the gate disagree about {}, so it was refused",
                name
            ),
        );
        return result(id, refused.line(), true);
    }
    match tools::run(&cap, arguments, sessions_dir) {
        Ok(data) => {
            let answered = Answer::answered("tool", data);
            result(id, answered.line(), false)
        }
        Err(why) => {
            let refused = Answer::refused("tool", RULE_GATE, &why);
            result(id, refused.line(), true)
        }
    }
}

/// declared_agrees answers whether the declaration and the gate say the same
/// thing about one capability. The gate here is the token: a capability the
/// declaration calls a change must ask for the human's token.
fn declared_agrees(cap: &tools::Capability) -> bool {
    !cap.mutates || cap.name.starts_with("multiplexer_")
}

/// token_given answers whether the arguments carry the human's token: the
/// server compares it with its own, so a caller cannot grant itself the
/// right to change a session.
fn token_given(arguments: &Value, sessions_dir: &PathBuf) -> bool {
    let given = arguments
        .get("confirm")
        .and_then(|value| value.as_str())
        .unwrap_or("");
    let own = engine_token(sessions_dir);
    !given.is_empty() && !own.is_empty() && given == own
}

/// engine_token answers the human's token: the environment first, then the
/// file in the sessions directory. The empty text means there is no token,
/// and a change is refused.
fn engine_token(sessions_dir: &PathBuf) -> String {
    match std::env::var("AIU_MULTIPLEXER_TOKEN") {
        Ok(from_env) if !from_env.is_empty() => from_env,
        _ => token_from_file(sessions_dir),
    }
}

/// token_from_file answers the token from the sessions directory, or the
/// empty text when the file is not there or holds nothing.
fn token_from_file(sessions_dir: &PathBuf) -> String {
    let file = sessions_dir.join("token");
    match std::fs::read_to_string(&file) {
        Ok(body) => body.trim().to_string(),
        Err(_) => String::new(),
    }
}

/// ok answers a request that succeeded.
fn ok(id: Value, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

/// error answers a request that could not be answered at all.
fn error(id: Value, code: i64, message: String) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message }
    })
}

/// result answers a tool call: the envelope as the text, and whether the
/// tool refused.
fn result(id: Value, text: String, is_error: bool) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "content": [ { "type": "text", "text": text } ],
            "isError": is_error
        }
    })
}

/// write_answer puts one answer on the standard output and flushes it, so
/// the caller sees it at once.
fn write_answer(answer: &Value) -> Result<(), String> {
    let mut text = answer.to_string();
    text.push('\n');
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    out.write_all(text.as_bytes())
        .map_err(|why| format!("the answer cannot be written: {}", why))?;
    out.flush()
        .map_err(|why| format!("the answer cannot be flushed: {}", why))
}
