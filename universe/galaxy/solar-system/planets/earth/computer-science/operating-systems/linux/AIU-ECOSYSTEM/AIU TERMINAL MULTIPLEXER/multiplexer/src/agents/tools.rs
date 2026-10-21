// One job: what an agent may do with the multiplexer — the declaration of
// the capabilities, and the work of each one over a session's wire.
//
// The declaration is DATA: the names, whether each one changes what a
// session does, and what it is for. The server checks the declaration
// against the gate before it runs anything, so a tool that lies is refused
// by name (rule 07).

use crate::wire;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// declaration is the capability declaration, carried inside the binary so
/// the server never looks for a file at runtime.
const DECLARATION: &str = include_str!("capabilities.json");

/// Capability is one thing an agent may do, as the declaration says it.
pub struct Capability {
    pub name: String,
    pub mutates: bool,
    pub description: String,
}

/// capabilities answers every declared capability, in the order of the
/// declaration.
pub fn capabilities() -> Vec<Capability> {
    let declared: Value = match serde_json::from_str(DECLARATION) {
        Ok(value) => value,
        Err(_) => return Vec::new(),
    };
    let list = match declared.as_array() {
        Some(items) => items.clone(),
        None => return Vec::new(),
    };
    list.iter()
        .filter_map(|item| {
            let name = item.get("name")?.as_str()?.to_string();
            let mutates = item.get("mutates").and_then(|v| v.as_bool()).unwrap_or(false);
            let description = item
                .get("description")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            Some(Capability {
                name,
                mutates,
                description,
            })
        })
        .collect()
}

/// of answers the capability of that name, or nothing.
pub fn of(name: &str) -> Option<Capability> {
    capabilities().into_iter().find(|cap| cap.name == name)
}

/// schema answers the input shape of one capability, the way the editor
/// declares it: the arguments in order, and the human's token when the tool
/// changes something.
pub fn schema(cap: &Capability) -> Value {
    let mut properties = serde_json::Map::new();
    properties.insert(
        "session".to_string(),
        json!({
            "type": "string",
            "description": "the session's name under the sessions directory"
        }),
    );
    properties.insert(
        "args".to_string(),
        json!({
            "type": "array",
            "description": "the arguments of the tool, in order"
        }),
    );
    properties.insert(
        "since".to_string(),
        json!({
            "type": "number",
            "description": "the record number to start from"
        }),
    );
    properties.insert(
        "data".to_string(),
        json!({
            "type": "string",
            "description": "the text to send to the session's shell"
        }),
    );
    properties.insert(
        "confirm".to_string(),
        json!({
            "type": "string",
            "description": "the human's token; a change needs it"
        }),
    );
    let required: Vec<Value> = if cap.mutates {
        vec![Value::from("confirm")]
    } else {
        Vec::new()
    };
    json!({
        "type": "object",
        "properties": Value::Object(properties),
        "required": Value::Array(required)
    })
}

/// run does the work of one capability and answers the data it produced.
pub fn run(cap: &Capability, arguments: &Value, sessions_dir: &Path) -> Result<Value, String> {
    match cap.name.as_str() {
        "multiplexer_sessions" => sessions(sessions_dir),
        "multiplexer_records" => {
            let session = named_session(arguments, sessions_dir)?;
            let since = arguments.get("since").and_then(|v| v.as_u64()).unwrap_or(0);
            let mut request = json!({ "op": "read", "client": "mux-mcp/1", "since": since });
            if let Some(text) = arguments.get("data").and_then(|v| v.as_str()) {
                request["data"] = Value::from(text);
            }
            let held = ask_holder(&session, request)?;
            Ok(json!({ "session": session_name(arguments), "records": held }))
        }
        "multiplexer_send" => {
            let session = named_session(arguments, sessions_dir)?;
            let data = arguments
                .get("data")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let request = json!({ "op": "send", "client": "mux-mcp/1", "data": data });
            let held = ask_holder(&session, request)?;
            Ok(json!({ "session": session_name(arguments), "records": held }))
        }
        other => Err(format!("there is no tool named {}", other)),
    }
}

/// sessions answers every session under the sessions directory, with what
/// each one holds right now.
fn sessions(sessions_dir: &Path) -> Result<Value, String> {
    let entries = std::fs::read_dir(sessions_dir)
        .map_err(|why| format!("the sessions directory {} cannot be read: {}", sessions_dir.display(), why))?;
    let mut held: Vec<Value> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let name = match path.file_name() {
            Some(found) => found.to_string_lossy().to_string(),
            None => continue,
        };
        let socket = path.join("holder.sock");
        if !socket.exists() {
            held.push(json!({
                "session": name,
                "held": false,
                "why": "no holder holds this session"
            }));
            continue;
        }
        let request = json!({ "op": "state", "client": "mux-mcp/1" });
        match ask_holder(&path, request) {
            Ok(records) => {
                let state = records
                    .last()
                    .cloned()
                    .unwrap_or(Value::Object(serde_json::Map::new()));
                let mut said = json!({ "session": name, "held": true });
                if let Some(outputs) = state.get("outputs") {
                    said["state"] = outputs.clone();
                }
                held.push(said);
            }
            Err(why) => held.push(json!({
                "session": name,
                "held": false,
                "why": why
            })),
        }
    }
    Ok(json!({ "sessions": held }))
}

/// named_session answers the session's directory from the arguments.
fn named_session(arguments: &Value, sessions_dir: &Path) -> Result<PathBuf, String> {
    let name = arguments
        .get("session")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string();
    if name.is_empty() {
        return Err("this tool needs the name of a session".to_string());
    }
    if name.contains('/') || name.contains("..") {
        return Err(format!("{} is not a session name", name));
    }
    Ok(sessions_dir.join(&name))
}

/// session_name answers the session's name as the arguments gave it.
fn session_name(arguments: &Value) -> String {
    arguments
        .get("session")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string()
}

/// ask_holder asks one session's holder and answers every record it sent.
fn ask_holder(session_dir: &Path, request: Value) -> Result<Vec<Value>, String> {
    let socket = session_dir.join("holder.sock");
    // The wait ends on the filesystem event that creates the socket, so an
    // agent that asks a moment after the session started is not refused for
    // a race it did not cause.
    wire::wait_for_socket(&socket)?;
    let fd = wire::connect(&socket)?;
    let asked = wire::ask(fd, &request);
    if let Err(why) = asked {
        wire::close(fd);
        return Err(why);
    }
    let mut held: Vec<Value> = Vec::new();
    let mut pending = String::new();
    let mut buffer = [0u8; 8192];
    loop {
        let got = match wire::read(fd, &mut buffer) {
            Ok(count) => count,
            Err(why) => {
                wire::close(fd);
                return Err(why);
            }
        };
        if got == 0 {
            break;
        }
        pending.push_str(&String::from_utf8_lossy(&buffer[..got]));
        while let Some(at) = pending.find('\n') {
            let line = pending[..at].trim().to_string();
            pending = pending[at + 1..].to_string();
            if line.is_empty() {
                continue;
            }
            match serde_json::from_str::<Value>(&line) {
                Ok(value) => held.push(value),
                Err(why) => {
                    wire::close(fd);
                    return Err(format!("the holder sent a line that is not a record: {}", why));
                }
            }
        }
    }
    wire::close(fd);
    Ok(held)
}
