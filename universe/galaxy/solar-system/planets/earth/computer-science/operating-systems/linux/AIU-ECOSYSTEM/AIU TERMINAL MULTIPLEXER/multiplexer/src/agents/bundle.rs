// One job: the context bundle — what the multiplexer sends to an agent. The
// shape is the contract's (=../../../contract/context-bundle-format.org=)
// and the editor's: the selection, the file, the position, the notation
// address and the why. The why is mandatory.
//
// A bundle carries NO agent-specific key: the adapter translates, and the
// program never learns which agent answers. A bundle carries NO secret: it
// passes the redaction seam, and an agent receives text and pointers, never
// credentials.
//
// A document is a header and then references: the paths, the addresses and
// the selections. An absent part stays absent; empty is not a value.

use serde_json::{json, Value};

#[path = "redact.rs"]
mod redact;

/// BOUNDARY is the version every bundle carries.
pub const BOUNDARY: &str = "1";

/// Bundle is what one send carries: the header, the selection, the file,
/// the position, the notation address and the why.
pub struct Bundle {
    pub program: String,
    pub project: String,
    pub target: String,
    pub selection: String,
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
            file: file.to_string(),
            position: position.to_string(),
            address: address.to_string(),
            why: why.to_string(),
        })
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
        lines.join("\n")
    }
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
}
