//! One job: the comments in the text — the spans the buffer keeps and the
//! renderer drops.
//! Registered in plan/package-tree.org (text/comments.rs).
//! TODO.org item 7 (step 6 of plan/build-order.org): comments are first-class
//! in text and stripped by rendering.
//!
//! What it reads, taken from the format and not invented here:
//!   * syntax/open-close-mark.org:34 — "Blocks nest: a comment block may sit
//!     inside a title block". A comment is therefore a block, written with the
//!     same mark as every other block:
//!         comment start
//!         a note for the owner, which the reader never sees
//!         comment end
//!   * rule A of syntax/first-slice-freeze.org — a block line is exactly two
//!     words, the name and `start`, or `end` and the name. So `comment start`
//!     opens a comment only when those two words are the whole line; the same
//!     two words inside a line of prose open nothing, as rule D already says for
//!     a code body.
//! No inline comment sign exists in the format yet and none is invented here;
//! an undecided shape is reported, not guessed.
//!
//! This area holds the text and nothing else (text/INDEX.org): no meaning, no
//! errors, no block names beyond the comment's own. Whether a body is opaque
//! is the parser's law (rule D), so a caller scans the range it has decided is
//! readable and the bytes of a code body are left alone unless it asks.

use crate::buffer::Buffer;
use crate::positions::{offset_to_line_col, LineCol};

/// The name a comment block carries, spelled the way the format already spells
/// it. TODO item 7.
pub const COMMENT_BLOCK_NAME: &str = "comment";

/// One comment, as the text keeps it: a byte span (start inclusive, end
/// exclusive), the 1-based line it opens on, and whether it was closed.
/// Offsets are bytes, by rule F of syntax/first-slice-freeze.org.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Comment {
    /// The first byte of the `comment start` line.
    pub start: usize,
    /// The first byte after the last comment line's text, its ending left out.
    /// An unterminated comment ends at the last byte of the scanned range.
    pub end: usize,
    /// The 1-based line of the `comment start` line.
    pub line: usize,
    /// False when the file ended inside the comment. The span is still exact
    /// and nothing panics; the caller reports it as a finding.
    pub closed: bool,
}

impl Comment {
    /// The comment's own bytes, exactly as written. The buffer keeps them:
    /// nothing in text/ deletes text.
    pub fn bytes<'a>(&self, buffer: &'a Buffer) -> &'a [u8] {
        buffer.slice(self.start, self.end)
    }

    /// True when the byte offset falls inside this comment.
    pub fn covers(&self, offset: usize) -> bool {
        offset >= self.start && offset < self.end
    }

    /// The line and character column of the comment's first byte, for a
    /// diagnosis.
    pub fn place(&self, buffer: &Buffer) -> LineCol {
        offset_to_line_col(buffer, self.start)
    }
}

/// Every comment in the whole buffer, in the order they appear. This is what
/// the renderer asks for when it drops comments. TODO item 7.
pub fn find_comments(buffer: &Buffer) -> Vec<Comment> {
    find_comments_in(buffer, 0, buffer.len())
}

/// Every comment whose `comment start` line falls inside the byte range
/// `from .. to`, in the order they appear. A caller that has decided a range
/// is not readable (an opaque code body, rule D) scans only the rest, so a
/// comment word in code is code. TODO item 7.
pub fn find_comments_in(buffer: &Buffer, from: usize, to: usize) -> Vec<Comment> {
    let mut out: Vec<Comment> = Vec::new();
    if to <= from {
        return out;
    }
    let first = buffer.line_at(from);
    let last = buffer.line_at(to - 1).min(buffer.line_count());
    let mut open: Option<(usize, usize)> = None;

    for line in first..=last {
        let mark = comment_mark(buffer.line_text(line));
        let start = buffer.line_start(line);
        match (open, mark) {
            (None, Some(CommentMark::Start)) => open = Some((start, line)),
            (Some((opened_at, opened_line)), Some(CommentMark::End)) => {
                out.push(Comment {
                    start: opened_at,
                    end: buffer.line_end(line),
                    line: opened_line,
                    closed: true,
                });
                open = None;
            }
            // anything else is content: a mark-less line inside a comment is
            // its body, and an end line with nothing open closes nothing.
            _ => {}
        }
    }

    // The file ended inside a comment. Its bytes are kept and the span says
    // exactly how far it reached; it is a finding, never a crash.
    if let Some((opened_at, opened_line)) = open {
        out.push(Comment {
            start: opened_at,
            end: buffer.line_end(last),
            line: opened_line,
            closed: false,
        });
    }
    out
}

/// True when the line `start .. end` is covered by a comment the renderer must
/// drop. A comment body line is not a block line and not a declaration line, so
/// only the comment spans say it goes. TODO item 7.
pub fn is_comment_line(comments: &[Comment], start: usize, end: usize) -> bool {
    comments.iter().any(|c| c.start < end && start < c.end)
}

/// Which comment mark a line carries, or None when it carries none. The test
/// is rule A's: the line is the two words, the name and `start` or `end` and
/// the name, and nothing else. Trailing spaces are ignored, as rule A says.
fn comment_mark(line: &str) -> Option<CommentMark> {
    let parts: Vec<&str> = line.trim_end().split_whitespace().collect();
    if parts.len() != 2 {
        return None;
    }
    match (parts[0], parts[1]) {
        (COMMENT_BLOCK_NAME, "start") => Some(CommentMark::Start),
        (COMMENT_BLOCK_NAME, "end") => Some(CommentMark::End),
        _ => None,
    }
}

/// The two marks a comment block is written with.
enum CommentMark {
    Start,
    End,
}

#[cfg(test)]
mod tests {
    //! A comment is a block, so it is written in the block form: `comment start`
    //! opens, `comment end` closes. Both halves are tested here, because a
    //! comment the scanner misses is a note the reader is shown.
    use super::*;

    #[test]
    fn the_marks_are_the_three_line_block_form() {
        assert!(matches!(comment_mark("comment start"), Some(CommentMark::Start)));
        assert!(matches!(comment_mark("comment end"), Some(CommentMark::End)));
        assert!(matches!(comment_mark("  comment start   "), Some(CommentMark::Start)));
        // The retired "end comment" closes nothing, and a mark with anything
        // else on the line is content.
        assert!(comment_mark("end comment").is_none());
        assert!(comment_mark("end").is_none());
        assert!(comment_mark("comment end because").is_none());
        assert!(comment_mark("a line that mentions comment start").is_none());
    }

    #[test]
    fn a_closed_comment_keeps_exactly_its_own_lines() {
        let text = "title start\ncomment start\na note\ncomment end\nA page\ntitle end\n";
        let buffer = Buffer::from_text(text);
        let comments = find_comments(&buffer);
        assert_eq!(comments.len(), 1);
        assert!(comments[0].closed);
        assert_eq!(comments[0].line, 2);
        assert_eq!(
            std::str::from_utf8(comments[0].bytes(&buffer)).unwrap(),
            "comment start\na note\ncomment end"
        );
    }

    #[test]
    fn a_comment_the_file_never_closed_is_still_found() {
        let text = "title start\ncomment start\na note\nA page\ntitle end\n";
        let buffer = Buffer::from_text(text);
        let comments = find_comments(&buffer);
        assert_eq!(comments.len(), 1);
        assert!(!comments[0].closed);
        assert_eq!(comments[0].line, 2);
    }
}
