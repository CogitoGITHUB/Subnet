//! One job: comments and marks stripped here, in one place.
//! Registered in plan/package-tree.org (rendering/strip.rs).
//!
//! strip.rs is the **only** stripper in the package. If another file decides to
//! drop a line, it calls this one; nobody re-implements the rule. It knows two
//! shapes of line and nothing about meaning:
//!   * a block line — "<name> start" or "<name> end",
//!   * a declaration line — "keyword: value" with a registered keyword.
//! Everything else is content and is kept exactly as written.

/// The registered declaration keywords, mirrored from parser/parser.rs. A line
/// whose keyword is not here is content, even when it has a colon in it.
pub const DECLARATION_KEYWORDS: [&str; 7] =
    ["tags", "language", "style", "theme", "color", "format", "font"];

/// True when the line is a block line: two words, the second "start" or "end".
pub fn is_block_line(line: &str) -> bool {
    let trimmed = line.trim_end();
    let parts: Vec<&str> = trimmed.split_whitespace().collect();
    parts.len() == 2 && (parts[1] == "start" || parts[1] == "end")
}

/// True when the line declares something with a registered keyword.
pub fn is_declaration_line(line: &str) -> bool {
    match line.find(':') {
        None => false,
        Some(colon) => {
            let keyword = line[..colon].trim();
            !keyword.is_empty() && DECLARATION_KEYWORDS.contains(&keyword)
        }
    }
}

/// True when the line is anything the reader should never see: a block line, a
/// declaration line, or a line that is only whitespace.
pub fn is_stripped(line: &str) -> bool {
    line.trim().is_empty() || is_block_line(line) || is_declaration_line(line)
}

/// Strip the marks: keep the content lines, drop everything that is only
/// syntax. Line endings are kept exactly as they came, so a stripped file
/// still has one newline per line it had.
pub fn strip_marks(text: &str) -> String {
    let mut out = String::new();
    for line in split_keeping_endings(text) {
        if !is_stripped(&line) {
            out.push_str(&line);
        }
    }
    out
}

/// Split text into lines, each keeping its own ending. A final line with no
/// ending stays that way, so nothing is invented.
fn split_keeping_endings(text: &str) -> Vec<&str> {
    let mut out: Vec<&str> = Vec::new();
    let mut start = 0usize;
    let bytes = text.as_bytes();
    for i in 0..bytes.len() {
        if bytes[i] == b'\n' {
            out.push(&text[start..=i]);
            start = i + 1;
        }
    }
    if start < text.len() {
        out.push(&text[start..]);
    }
    out
}