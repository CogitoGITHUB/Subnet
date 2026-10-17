//! One job: the plain fallback — text out, nothing invented.
//! Registered in plan/package-tree.org (rendering/plain.rs).
//!
//! Plain rendering shows what the reader wrote and nothing else: the block
//! lines and the declaration lines are gone, the content is kept word for word
//! (syntax/first-slice-freeze.org, rule F: rendering hides start, end and
//! declaration lines and keeps content).
//!
//! It adds nothing of its own: no headings, no numbering, no box drawing, no
//! line it invented. If a future tier wants any of that, it goes in
//! rendering/rich.rs, not here.
//!
//! The only place anything is dropped is strip.rs. This file decides what to
//! say about what is left, and it says exactly what was left.

use crate::strip::strip_marks;

/// Render the plain form of a page. The input is the file's own text; the
/// output is the same text with the marks removed.
pub fn render_plain(text: &str) -> String {
    strip_marks(text)
}

/// Render the plain form of one block's body, given the body text only. Used
/// by callers that already hold a span from the tree.
pub fn render_body(text: &str) -> String {
    strip_marks(text)
}

/// How many content lines the plain form has. A caller that needs to say
/// "nothing was left" counts here instead of guessing from an empty string.
pub fn content_line_count(text: &str) -> usize {
    render_plain(text)
        .lines()
        .filter(|l| !l.trim().is_empty())
        .count()
}