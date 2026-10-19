//! One job: comments and marks stripped here, in one place.
//! Registered in plan/package-tree.org (rendering/strip.rs).
//!
//! strip.rs is the **only** stripper in the package. If another file decides to
//! drop a line, it calls this one; nobody re-implements the rule. It knows two
//! shapes of line and nothing about meaning:
//!   * a block line — "<name> start" or "end <name>",
//!   * a declaration line — "keyword: value" with a registered keyword.
//! Everything else is content and is kept exactly as written.
//!
//! Comments are the third thing it drops, and the spans come from text/:
//! text/comments.rs says where they are (TODO item 7). This file never reads a
//! comment itself, only the byte ranges it must drop, so there is exactly one
//! place that knows what a comment is and one place that removes it.

use crate::buffer::Buffer;
use crate::comments::{find_comments, is_comment_line};

/// The registered declaration keywords, mirrored from parser/parser.rs. A line
/// whose keyword is not here is content, even when it has a colon in it.
pub const DECLARATION_KEYWORDS: [&str; 7] =
    ["tags", "language", "style", "theme", "color", "format", "font"];

/// True when the line is a block line: the two words "<name> start", or the two
/// words "end <name>". Anything else, including the retired "<name> end", is
/// content.
pub fn is_block_line(line: &str) -> bool {
    let trimmed = line.trim_end();
    let parts: Vec<&str> = trimmed.split_whitespace().collect();
    parts.len() == 2 && (parts[1] == "start" || parts[0] == "end")
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
/// declaration line, or a line that is only whitespace. A line inside a
/// comment is not judged here — it needs the span, not the shape.
pub fn is_stripped(line: &str) -> bool {
    line.trim().is_empty() || is_block_line(line) || is_declaration_line(line)
}

/// Strip the marks and the comments: keep the content lines, drop everything
/// that is only syntax. Line endings are kept exactly as they came, so a
/// stripped file still has one newline per line it had, and the dropped lines
/// take their own endings with them so the kept lines stay whole.
pub fn strip_marks(text: &str) -> String {
    let buffer = Buffer::from_text(text);
    let comments = find_comments(&buffer);
    let mut out = String::new();
    for line in 1..=buffer.line_count() {
        let start = buffer.line_start(line);
        let end = buffer.line_end(line);
        if is_comment_line(&comments, start, end) {
            continue;
        }
        if is_stripped(buffer.line_text(line)) {
            continue;
        }
        // line_bytes keeps the line's own ending, so nothing is re-invented
        out.push_str(std::str::from_utf8(buffer.line_bytes(line)).unwrap_or(""));
    }
    out
}

#[cfg(test)]
mod tests {
    //! The stripper, on both spellings of the block form. If it drops a line
    //! the reader wrote, or keeps a line that is only syntax, the renderers
    //! inherit the mistake, so the test lives here and not in either tier.
    use super::*;

    #[test]
    fn both_spellings_of_a_block_line_are_block_lines() {
        assert!(is_block_line("title start"));
        assert!(is_block_line("end title"));
        assert!(is_block_line("code start   "));
        assert!(is_block_line("   end code"));
        // The retired "<name> end" is content now, and so is a mark with
        // anything else on the line.
        assert!(!is_block_line("title end"));
        assert!(!is_block_line("end"));
        assert!(!is_block_line("end code because"));
        assert!(!is_block_line("the code start of the file"));
    }

    #[test]
    fn strip_marks_keeps_the_body_and_drops_the_marks() {
        let text = "title start\ntags: sample\nA page\nend title\n\ncode start\nlanguage: text\nend code\n";
        let kept = strip_marks(text);
        assert_eq!(kept, "A page\n");
        assert_eq!(is_stripped("end title"), true);
        assert_eq!(is_stripped("a sentence"), false);
    }

    #[test]
    fn a_comment_in_the_three_line_form_is_dropped_with_its_body() {
        let text = "title start\ncomment start\na note for the owner\nend comment\nA page\nend title\n";
        let kept = strip_marks(text);
        assert_eq!(kept, "A page\n");
    }
}
