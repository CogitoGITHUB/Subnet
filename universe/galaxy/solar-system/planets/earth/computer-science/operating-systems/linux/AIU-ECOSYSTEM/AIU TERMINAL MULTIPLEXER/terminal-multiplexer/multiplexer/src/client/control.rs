// One job: the agent's hands — the request that comes from the agent, the
// words it carries, and the answer that goes back.
//
// The agent gets no commands of its own. It sends the words the owner types
// on the command line, and the screen runs them through the same code: the
// tabs, the splits, the scroll and the copy are the owner's commands, and
// the agent's words are the owner's words. What the screen did is what the
// agent is told.
//
// The read is free. A change is the owner's: the holder checks the human's
// token before the words go to the screen (rule 07), and this file is only
// the path the words travel.

use serde_json::{json, Value};

use crate::screen::{Action, Screen};

/// Outcome is what the screen did with the agent's words: what it must ask
/// the holder, if anything.
pub struct Outcome {
    /// ask is what the screen must ask the holder, if anything.
    pub ask: Option<Value>,
}

/// is_request answers whether one record from the holder is the agent's
/// request and not a record of the session.
pub fn is_request(record: &Value) -> bool {
    matches!(
        record.get("kind").and_then(|kind| kind.as_str()),
        Some("control") | Some("view")
    )
}

/// request_of answers the id of the agent's request and the words it sent.
/// A request with no words is the agent's read of the screen.
pub fn request_of(record: &Value) -> (String, Vec<String>) {
    let inputs = record.get("inputs").cloned().unwrap_or(Value::Null);
    let id = inputs
        .get("id")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string();
    let words = inputs
        .get("words")
        .and_then(|value| value.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|one| one.as_str().map(|text| text.to_string()))
                .collect()
        })
        .unwrap_or_default();
    (id, words)
}

/// run runs the agent's words on the screen and answers what it must ask of
/// the holder. The answer the agent gets comes later: the screen asks the
/// holder for the state first, so the agent is told the state as it stands.
pub fn run(screen: &mut Screen, words: &[String]) -> Outcome {
    let said = words.join(" ");
    let action = screen.control_words(&said);
    let ask = match action {
        Action::Request(request) => Some(request),
        Action::Send(bytes) => Some(json!({
            "op": "send",
            "pane": screen.focused_pane(),
            "data": String::from_utf8_lossy(&bytes).to_string(),
        })),
        _ => None,
    };
    Outcome { ask }
}

/// answer is the record the screen sends back to the holder: the id of the
/// request and what the screen did. The holder carries it to the agent that
/// asked.
pub fn answer(id: &str, data: &Value) -> Value {
    json!({
        "op": "control-result",
        "id": id,
        "data": data
    })
}
