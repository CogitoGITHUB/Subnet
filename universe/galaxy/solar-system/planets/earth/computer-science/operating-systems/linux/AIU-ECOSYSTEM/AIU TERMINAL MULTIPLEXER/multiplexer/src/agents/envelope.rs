// One job: the one envelope every surface answers with.
//
// The CLI, the MCP server, the skill and the plugin all send this shape, so
// an agent reads this program the same way whatever it came in through. The
// field names and their order are the editor's, so the two programs answer
// in one shape.

use serde_json::Value;

/// exit-ok is the code of an answer: the program answered, and the answer
/// is an answer.
pub const EXIT_OK: i32 = 0;

/// exit-refusal is the code of a refusal: the program refused, and it named
/// the rule it refused by.
pub const EXIT_REFUSAL: i32 = 2;

/// exit-cannot-run is the code of a program that could not answer at all.
pub const EXIT_CANNOT_RUN: i32 = 3;

/// program is the program that answers.
pub const PROGRAM: &str = "aiu-multiplexer";

/// version is the version of the shape.
pub const VERSION: &str = "1";

/// answer is one envelope: what kind of answer it is, whether it is an
/// answer, the data, the refusal and the events.
pub struct Answer {
    pub kind: String,
    pub ok: bool,
    pub data: Value,
    pub refusal: Value,
    pub events: Value,
}

impl Answer {
    /// answered is the envelope of an answer that carries data.
    pub fn answered(kind: &str, data: Value) -> Answer {
        Answer {
            kind: kind.to_string(),
            ok: true,
            data,
            refusal: Value::Object(serde_json::Map::new()),
            events: Value::Array(Vec::new()),
        }
    }

    /// refused is the envelope of a refusal: the rule is named in it, so a
    /// reader knows which rule stopped the call.
    pub fn refused(kind: &str, rule: &str, message: &str) -> Answer {
        let mut refusal = serde_json::Map::new();
        refusal.insert("rule".to_string(), Value::from(rule));
        refusal.insert("message".to_string(), Value::from(message));
        Answer {
            kind: kind.to_string(),
            ok: false,
            data: Value::Object(serde_json::Map::new()),
            refusal: Value::Object(refusal),
            events: Value::Array(Vec::new()),
        }
    }

    /// line answers the envelope as one line of JSON, in the field order the
    /// editor uses: program, version, kind, ok, data, refusal, events.
    pub fn line(&self) -> String {
        format!(
            "{{\"program\":\"{}\",\"version\":\"{}\",\"kind\":{},\"ok\":{},\"data\":{},\"refusal\":{},\"events\":{}}}",
            PROGRAM,
            VERSION,
            quoted(&self.kind),
            self.ok,
            self.data,
            self.refusal,
            self.events
        )
    }
}

/// quoted answers one string as a JSON string.
fn quoted(text: &str) -> String {
    Value::from(text).to_string()
}
