// One job: the editor's own answer, drawn as lines.
//
// The answer is the editor's own words: the multiplexer does not rewrite
// them and does not explain them. A refusal is shown as a refusal, with the
// reason the editor gave.

use serde_json::Value;

/// lines answers the panel of the editor's own answer: what the editor said,
/// one line per row of it.
///
/// An answer that carries no words is said so: an empty panel is not an
/// answer, and the owner must not read one as one.
pub fn lines(data: &Value) -> Vec<String> {
    let why = data
        .get("why")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    if !why.is_empty() {
        return vec![format!("the editor did not answer: {}", why)];
    }
    let capability = data
        .get("capability")
        .and_then(|value| value.as_str())
        .unwrap_or("");
    let took = data
        .get("took-ms")
        .and_then(|value| value.as_u64())
        .unwrap_or(0);
    let text = data
        .get("text")
        .and_then(|value| value.as_str())
        .unwrap_or("");
    let mut panel = vec![format!(
        "the editor answered: {} ({} ms)",
        capability, took
    )];
    for line in text.lines() {
        panel.push(line.to_string());
    }
    if text.trim().is_empty() {
        panel.push("the editor said nothing at all".to_string());
    }
    panel
}
