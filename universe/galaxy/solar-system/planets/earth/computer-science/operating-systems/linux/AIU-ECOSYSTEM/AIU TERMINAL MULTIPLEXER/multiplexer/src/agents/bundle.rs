// One job: the context bundle — what the multiplexer sends to an agent. The
// shape is the contract's (=../../../contract/context-bundle-format.org=)
// and the editor's: the selection, the command record, the file, the
// position, the notation address and the why. The why is mandatory.
//
// The command record is a pane's nushell command and what it printed,
// together: a command is selectable and sendable, and it travels in the same
// bundle as the selection, so an agent reads the command and its output as
// one thing.
//
// A bundle carries NO agent-specific key: the adapter translates, and the
// program never learns which agent answers. A bundle carries NO secret: it
// passes the redaction seam, and an agent receives text and pointers, never
// credentials.
//
// A document is a header and then references: the paths, the addresses, the
// selections and the command record. An absent part stays absent; empty is
// not a value.

use serde_json::{json, Value};

#[path = "redact.rs"]
mod redact;

/// BOUNDARY is the version every bundle carries.
pub const BOUNDARY: &str = "1";

/// Bundle is what one send carries: the header, the selection, the command
/// record, the file, the position, the notation address and the why.
pub struct Bundle {
    pub program: String,
    pub project: String,
    pub target: String,
    pub selection: String,
    /// command is the command a pane was given, and output is what the pane
    /// printed after it: one record, two parts.
    pub command: String,
    pub output: String,
    pub file: String,
    pub position: String,
    pub address: String,
    pub why: String,
}

impl Bundle {
    /// make answers a bundle, or nothing when the why is blank: a send
    /// without a reason is refused, because a send nobody can explain is a
    /// send that cannot be audited.
    ///
    /// The selection passes the redaction seam on the way in, so a bundle
    /// never carries a credential.
    pub fn make(
        program: &str,
        project: &str,
        target: &str,
        selection: &str,
        file: &str,
        position: &str,
        address: &str,
        why: &str,
    ) -> Option<Bundle> {
        if why.trim().is_empty() {
            return None;
        }
        Some(Bundle {
            program: program.to_string(),
            project: project.to_string(),
            target: target.to_string(),
            selection: redact::redact_text(selection),
            command: String::new(),
            output: String::new(),
            file: file.to_string(),
            position: position.to_string(),
            address: address.to_string(),
            why: why.to_string(),
        })
    }

    /// carrying answers the bundle with a command record attached: the
    /// command a pane's shell was given, and what that pane printed after it.
    /// Both parts pass the redaction seam here, exactly as the selection does,
    /// so the record travels the way the rest of the bundle travels.
    pub fn carrying(mut self, command: &str, output: &str) -> Bundle {
        self.command = redact::redact_text(command.trim_end());
        self.output = redact::redact_text(output.trim_end());
        self
    }

    /// header answers the header every bundle carries: the boundary
    /// version, the program that sends, the project it sends from, and the
    /// named target agent. The target is named, never inferred.
    pub fn header(&self) -> Value {
        json!({
            "boundary": BOUNDARY,
            "program": self.program,
            "project": self.project,
            "target": self.target,
        })
    }

    /// document answers the document of a bundle: the header, then the
    /// references — the paths, the addresses and the selections. An absent
    /// part is left out, so the document says what is there.
    pub fn document(&self) -> Value {
        let mut references: Vec<Value> = Vec::new();
        if !self.file.is_empty() {
            references.push(json!({ "path": self.file }));
        }
        if !self.position.is_empty() {
            references.push(json!({ "position": self.position }));
        }
        if !self.address.is_empty() {
            references.push(json!({ "address": self.address }));
        }
        if !self.selection.is_empty() {
            references.push(json!({ "selection": self.selection }));
        }
        if !self.command.is_empty() {
            references.push(json!({ "command": self.command }));
        }
        if !self.output.is_empty() {
            references.push(json!({ "output": self.output }));
        }
        json!({
            "header": self.header(),
            "references": references,
        })
    }

    /// text answers the text of a bundle: the document as the agent reads
    /// it, one part per line. It is the same text a person reads, so what
    /// the agent gets is never a different thing from what the human saw.
    pub fn text(&self) -> String {
        let mut lines: Vec<String> = Vec::new();
        lines.push(format!(
            "boundary: {}  program: {}  project: {}  target: {}",
            BOUNDARY, self.program, self.project, self.target
        ));
        lines.push(format!("why: {}", self.why));
        if !self.file.is_empty() {
            lines.push(format!("path: {}", self.file));
        }
        if !self.position.is_empty() {
            lines.push(format!("position: {}", self.position));
        }
        if !self.address.is_empty() {
            lines.push(format!("address: {}", self.address));
        }
        if !self.selection.is_empty() {
            lines.push(format!("selection: {}", self.selection));
        }
        if !self.command.is_empty() {
            lines.push(format!("command: {}", self.command));
        }
        if !self.output.is_empty() {
            lines.push(format!("output: {}", self.output));
        }
        lines.join("\n")
    }
}

/// carries_no_secret answers whether a text holds something the seam would
/// hide: the receiving side of a delivery asks this, so a bundle that
/// arrives with a secret in it is refused by name rather than written to an
/// agent's terminal.
pub fn carries_no_secret(text: &str) -> bool {
    !redact::carries_a_secret(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bundle() -> Bundle {
        Bundle::make(
            "aiu-multiplexer",
            "aiu-ecosystem",
            "opencode",
            "the build finished",
            "",
            "",
            "",
            "the owner asked for the agent beside this pane",
        )
        .expect("the bundle is made")
    }

    #[test]
    fn a_bundle_without_a_why_is_refused() {
        let refused = Bundle::make("aiu-multiplexer", "aiu-ecosystem", "opencode", "text", "", "", "", "  ");
        assert!(refused.is_none(), "a send without a reason is refused");
    }

    #[test]
    fn the_text_of_a_bundle_is_the_shape_the_editor_writes() {
        let text = bundle().text();
        let lines: Vec<&str> = text.split('\n').collect();
        assert_eq!(
            lines[0],
            "boundary: 1  program: aiu-multiplexer  project: aiu-ecosystem  target: opencode"
        );
        assert_eq!(
            lines[1],
            "why: the owner asked for the agent beside this pane"
        );
        assert_eq!(lines[2], "selection: the build finished");
        assert_eq!(lines.len(), 3, "the bundle says what is there: {}", text);
    }

    #[test]
    fn an_absent_part_stays_absent() {
        let document = bundle().document();
        let references = document.get("references").expect("the references are there");
        assert_eq!(references.as_array().expect("a list").len(), 1);
    }

    #[test]
    fn a_bundle_passes_the_redaction_seam() {
        let made = Bundle::make(
            "aiu-multiplexer",
            "aiu-ecosystem",
            "opencode",
            "password: hunter2",
            "",
            "",
            "",
            "the owner asked",
        )
        .expect("the bundle is made");
        assert!(!made.text().contains("hunter2"), "the secret left: {}", made.text());
        assert!(made.text().contains("[redacted]"), "the redaction is not marked");
    }

    #[test]
    fn the_command_record_travels_with_the_selection() {
        let made = bundle().carrying("ls -la", "total 0\ndrwxr-xr-x 2");
        let document = made.document();
        let references = document
            .get("references")
            .and_then(|value| value.as_array())
            .expect("the references are there");
        let keys: Vec<String> = references
            .iter()
            .filter_map(|reference| reference.as_object())
            .filter_map(|object| object.keys().next().cloned())
            .collect();
        assert_eq!(
            keys,
            vec!["selection", "command", "output"],
            "the record travels with the selection"
        );
        let text = made.text();
        assert!(text.contains("selection: the build finished"), "{}", text);
        assert!(text.contains("command: ls -la"), "{}", text);
        assert!(text.contains("output: total 0"), "{}", text);
    }

    #[test]
    fn the_command_record_passes_the_redaction_seam() {
        let made = bundle().carrying("export api_key=sk-abcdef", "sk-abcdef");
        let text = made.text();
        assert!(!text.contains("sk-abcdef"), "the secret left: {}", text);
        // The seam keeps the name and drops the value: the separator goes
        // with the value, exactly as it does for every other line.
        assert!(text.contains("command: export api_key[redacted]"), "{}", text);
        assert!(text.contains("output: [redacted]"), "{}", text);
    }

    #[test]
    fn a_bundle_without_a_command_record_says_nothing_of_one() {
        let text = bundle().text();
        assert!(!text.contains("command:"), "{}", text);
        assert!(!text.contains("output:"), "{}", text);
    }

    #[test]
    fn the_seam_answers_whether_a_text_would_change_on_its_way_out() {
        assert!(carries_no_secret("the build finished"));
        assert!(!carries_no_secret("password: hunter2"));
    }
}
