// One job: the redaction seam — what may not leave this program.
//
// The seam is where a secret is stopped. The multiplexer sends text to an
// agent, and the text may hold a credential by accident: a key in a picked
// line, a password in a line the owner sent. The seam replaces what looks
// like a secret with a marker, and the marker says that something was
// hidden — a reader sees that a redaction happened instead of missing it.
//
// The seam keeps the NAME and drops the VALUE: a line that reads
// "api_key = sk-..." comes out as "api_key [redacted]", so a reader can
// see that a credential was there and is not now, and can ask for it by
// name.
//
// These are the editor's rules, the same ones, so the same text is redacted
// the same way in both programs.

/// SECRET_WORDS name a credential, or hold a token that has the shape of
/// one.
const SECRET_WORDS: [&str; 11] = [
    "api_key",
    "api-key",
    "apikey",
    "password",
    "passwd",
    "secret",
    "token",
    "authorization",
    "sk-",
    "bearer ",
    "-----begin",
];

/// REDACTION is the marker that says a value was hidden.
const REDACTION: &str = "[redacted]";

/// carries_a_secret answers whether a text holds something the seam would
/// hide: a line that names a credential and does not already carry the
/// marker. A marked line is safe, so the question is about the value and not
/// about the name — the name stays in the text on purpose.
pub fn carries_a_secret(text: &str) -> bool {
    text.split('\n')
        .any(|line| names_a_credential(line) && !line.trim_end().ends_with(REDACTION))
}

/// redact_text answers the text with everything that looks like a secret
/// taken out of it.
pub fn redact_text(text: &str) -> String {
    text.split('\n')
        .map(|line| {
            if names_a_credential(line) {
                hide_value(line)
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<String>>()
        .join("\n")
}

/// names_a_credential answers whether the line names a credential or holds
/// a token that has the shape of one.
fn names_a_credential(line: &str) -> bool {
    let lower = line.to_lowercase();
    SECRET_WORDS.iter().any(|word| lower.contains(word))
}

/// separator_at answers where the value of a line begins: the first colon
/// or the first equals sign, whichever comes first. A line with neither has
/// no value, and the whole line is hidden.
fn separator_at(line: &str) -> Option<usize> {
    let colon = line.find(':');
    let equals = line.find('=');
    match (colon, equals) {
        (None, None) => None,
        (Some(at), None) => Some(at),
        (None, Some(at)) => Some(at),
        (Some(one), Some(other)) => Some(if one < other { one } else { other }),
    }
}

/// hide_value answers the line with its value taken out and its name left
/// in.
fn hide_value(line: &str) -> String {
    match separator_at(line) {
        Some(at) => format!("{}[redacted]", &line[..at]),
        None => "[redacted]".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_that_names_a_credential_keeps_its_name_and_loses_its_value() {
        let redacted = redact_text("api_key = sk-1234567890");
        assert_eq!(redacted, "api_key [redacted]");
    }

    #[test]
    fn a_token_that_has_the_shape_of_one_is_hidden() {
        let redacted = redact_text("sk-abcdefghijklmnop");
        assert_eq!(redacted, "[redacted]");
    }

    #[test]
    fn an_ordinary_line_is_left_alone() {
        let redacted = redact_text("the build finished in 4 seconds");
        assert_eq!(redacted, "the build finished in 4 seconds");
    }

    #[test]
    fn every_line_of_a_pane_is_seen() {
        let redacted = redact_text("first line\npassword: hunter2\nlast line");
        // The seam keeps the name and drops the value, exactly as the
        // editor's seam does: the colon is the separator and it goes too.
        assert_eq!(
            redacted,
            "first line\npassword[redacted]\nlast line"
        );
    }

    #[test]
    fn a_marked_line_holds_no_secret_any_more() {
        assert!(carries_a_secret("export api_key=sk-abcdef"));
        assert!(!carries_a_secret("export api_key[redacted]"));
        assert!(!carries_a_secret("the build finished in 4 seconds"));
    }
}
