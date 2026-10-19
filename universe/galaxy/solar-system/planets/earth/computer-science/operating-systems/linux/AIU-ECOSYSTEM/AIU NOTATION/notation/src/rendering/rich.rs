//! One job: the rich tier — the plain tier's content, drawn with unicode.
//! Registered in plan/package-tree.org (rendering/rich.rs).
//! TODO.org item 9, step 8 of plan/build-order.org: plain and rich unicode on
//! the phone; the graphics tier stays planned, and this file keeps that honest.
//!
//! What is drawn, and what each mark means:
//!   * a title block is a heading: its own words, then a `═` rule under them,
//!   * a code block is a box — `┌ ┐ │ └ ┘` — because its body is opaque and the
//!     box says so without a word,
//!   * a paragraph is its own lines, indented two columns per nesting level,
//!   * a block whose `style:` or `format:` declaration asks for bold, strong,
//!     italic or emphasis gets a `▌` mark in the left margin,
//!   * an error node is its own words after a `✗ line N` mark: the reader is
//!     told where to look and is told nothing else.
//! Every glyph is an ordinary character in the text. No colour, no escape
//! code, no attribute this file writes.
//!
//! Where the content comes from — the seam with the other tiers:
//!   * strip.rs decides what a line is. This file asks it
//!     (`is_block_line`, `is_declaration_line`) and never decides again, so the
//!     two tiers cannot drift apart on what is syntax.
//!   * text/comments.rs says where the comments are; this file drops those
//!     spans and nothing else.
//!   * the plain tier's `content_line_count` decides whether anything was left,
//!     so an empty page is empty for both tiers.
//!   * the walk over the tree lives once, in `render_node_rich`. The file entry
//!     point parses and calls it; a caller that already holds a node calls the
//!     same one. There is no second walk to fall out of step with the first.
//!   * a node kind with no rich shape falls back to the plain rendering of its
//!     own span, so it never panics and never loses words.
//!
//! Width: the caller says how many columns the screen has. Nothing here asks
//! the terminal, reads an environment variable or detects anything at all.
//! Width 0 means "do not wrap" — every line is shown whole.
//!
//! What this tier deliberately cannot do — item 9 keeps this list honest:
//!   * No graphics tier. Item 9 records it unproven; drawing into a frame
//!     buffer is a different tier, not more glyphs here.
//!   * No image, no figure, no hyperlink: a link would put bytes on the screen
//!     that the reader cannot follow, and the freeze keeps inline links open.
//!   * No colour and no escape codes. Bold and italic are asked for as
//!     declarations and answered with a mark in the margin.
//!   * No tables, no numbering, no cross references: package-tree.org names
//!     tables here as planned, and a Tier 2 element decides their meaning
//!     before a renderer draws them.
//!   * Code is never re-wrapped, re-indented or cut. A line too wide for the
//!     screen overflows and scrolls; it does not lose characters.
//!
//! Two open questions for the owner, stated here rather than decided here:
//!   * Rule D keeps blank lines inside a paragraph for the reader, and
//!     strip.rs drops them today. This tier follows strip.rs, so both tiers
//!     show the same words; the fix, if it is one, belongs in strip.rs, the
//!     only stripper.
//!   * Emphasis reads registered declarations (`style:`, `format:`) only.
//!     Inline emphasis inside a paragraph stays open in
//!     syntax/first-slice-freeze.org, so no inline mark is invented here.

use crate::buffer::Buffer;
use crate::comments::{find_comments_in, is_comment_line, Comment};
use crate::parser::{parse, Block, ErrorNode, Node, Span};
use crate::plain;
use crate::strip::{is_block_line, is_declaration_line};

/// The left and right edge of the code box.
pub const BOX_SIDE: char = '│';
/// The horizontal run: the box's top and bottom rails.
pub const BOX_HORIZONTAL: char = '─';
/// The top corners of the code box.
pub const BOX_TOP_LEFT: char = '┌';
/// The other top corner of the code box.
pub const BOX_TOP_RIGHT: char = '┐';
/// The bottom corners of the code box.
pub const BOX_BOTTOM_LEFT: char = '└';
/// The bottom corner on the other side of the code box.
pub const BOX_BOTTOM_RIGHT: char = '┘';
/// The rule drawn under a heading. Heavy, so a heading is not mistaken for a
/// paragraph that happens to be bold.
pub const HEADING_RULE: char = '═';
/// The mark in the left margin of a block that asked to be emphasized: a half
/// block, one column, drawn once per line of that block's body.
pub const EMPHASIS_MARK_LINE: &str = "▌ ";
/// The mark in front of an error node's own words: where to look.
pub const ERROR_MARK: char = '✗';
/// How far an error node's own words sit under its mark.
pub const ERROR_BODY_INDENT: usize = 2;

/// The `style:` and `format:` values that mean "this block's body is
/// emphasized". Rule B keeps styling a hint and never meaning, so a value that
/// is not on this list is ignored, not guessed at.
pub const EMPHASIS_VALUES: [&str; 4] = ["bold", "strong", "italic", "emphasis"];

/// How many columns one level of nesting costs. Two is what a phone terminal
/// shows comfortably; a third level still reads.
pub const BLOCK_INDENT: usize = 2;

/// The narrowest text column the tier will draw into. Nesting deeper than this
/// costs no further indent: a narrow screen gets a tall page, not a page whose
/// words are pushed off it.
pub const MINIMUM_TEXT_COLUMNS: usize = 8;

/// What the rich tier says when the plain tier found nothing left to show. It
/// counts rather than guesses from an empty string (plain.rs).
pub const NOTHING_LEFT: &str =
    "(nothing was left to render: every line was a mark, a declaration or a comment)";

/// Render a file's rich form. The signature follows the plain tier's: the
/// file's own text in, a string out, nothing else asked of it — plus the width,
/// which only the caller knows.
pub fn render_rich(text: &str, width: usize) -> String {
    // The plain tier decides what is left, so the two tiers can never disagree
    // about an empty page.
    if plain::content_line_count(text) == 0 {
        return NOTHING_LEFT.to_string();
    }
    let buffer = Buffer::from_text(text);
    let tree = parse(&buffer);
    let mut out = String::new();
    for node in &tree.nodes {
        push_section(&mut out, &render_node_rich(node, &buffer, width, 0));
    }
    if out.is_empty() {
        // Nothing important is silent: an empty page says so rather than
        // printing nothing at all.
        return NOTHING_LEFT.to_string();
    }
    out
}

/// Render one node of the tree with the rich tier's marks, `depth` levels in.
/// A caller that already holds a node — the editor's notation mode, the
/// `check` command — calls this instead of `render_rich`, and there is only
/// this one walk either way.
pub fn render_node_rich(node: &Node, buffer: &Buffer, width: usize, depth: usize) -> String {
    match rich_shape(node, buffer, width, depth) {
        Some(section) => section,
        // No rich shape for this kind of node. The plain rendering of its own
        // span is shown instead: the words are the reader's, the markup is
        // gone, and nothing panics over a kind nobody drew yet.
        None => plain::render_body(span_text(node.span(), buffer)),
    }
}

/// The rich shape of a node, or None when this file has not drawn that kind
/// yet. The match is exhaustive over today's `Node`, so a kind added later is a
/// compile error until it is routed here — either to a shape or to None, which
/// is the plain fallback above.
fn rich_shape(node: &Node, buffer: &Buffer, width: usize, depth: usize) -> Option<String> {
    match node {
        Node::Block(block) => Some(block_section(block, buffer, width, depth)),
        Node::Error(error) => Some(error_section(error, buffer, width, depth)),
    }
}

/// One block: its own body in its own shape, then whatever nests inside it.
fn block_section(block: &Block, buffer: &Buffer, width: usize, depth: usize) -> String {
    let indent = indent_for(depth, width);
    let body = lines_of_span(block.span, buffer, &readable_comments(block, buffer));
    let mark = if asks_for_emphasis(block) { EMPHASIS_MARK_LINE } else { "" };
    // The mark and the indent both cost columns before a word may start.
    let columns = width.saturating_sub(indent + column_count(mark));
    let mut section = match block.name.as_str() {
        "title" => heading_lines(&body, columns, indent),
        "paragraph" => paragraph_lines(&body, columns, indent, mark),
        "code" => code_box_lines(&body, columns, indent),
        // The parser turns an unregistered name into an error node before a
        // block with that name ever reaches here, so this arm only runs for a
        // tree built by hand. No name is drawn and the body is drawn as prose:
        // the plainest rich shape there is, and the words stay the reader's.
        _ => paragraph_lines(&body, columns, indent, mark),
    };
    for child in &block.children {
        push_section(&mut section, &render_node_rich(child, buffer, width, depth + 1));
    }
    section
}

/// One error node: the mark, the line to look at, then that node's own words.
/// Nothing the parser generated is printed — this tier shows what the file
/// says, and the mark says where to look.
fn error_section(error: &ErrorNode, buffer: &Buffer, width: usize, depth: usize) -> String {
    let indent = indent_for(depth, width);
    let columns = width.saturating_sub(indent);
    let own = lines_of_span(error.span, buffer, &[]);
    let mut out = format!("{}{} line {}", " ".repeat(indent), ERROR_MARK, error.line);
    // The text is the reader's own line, wrapped as prose like a paragraph.
    let body = paragraph_lines(
        &own,
        columns.saturating_sub(ERROR_BODY_INDENT),
        indent.saturating_add(ERROR_BODY_INDENT),
        "",
    );
    if !body.is_empty() {
        out.push('\n');
        out.push_str(&body);
    }
    out
}

/// A heading: the words wrapped to the width, then a rule as wide as the
/// longest line under it. The rule stops at the widest word, so a short title
/// does not draw a line across a phone.
fn heading_lines(lines: &[&str], columns: usize, indent: usize) -> String {
    let pad = " ".repeat(indent);
    let mut out = String::new();
    let mut widest = 0usize;
    for line in lines {
        for piece in wrap_line(line, columns) {
            widest = widest.max(column_count(&piece));
            push_line(&mut out, &format!("{}{}", pad, piece));
        }
    }
    if !out.is_empty() && widest > 0 {
        push_line(&mut out, &format!("{}{}", pad, HEADING_RULE.to_string().repeat(widest)));
    }
    out
}

/// Prose: the lines the reader wrote, wrapped to the columns that are left
/// after the indent and the emphasis mark. No word is added, dropped or
/// reordered; where a break fell is a screen decision, not a text change.
fn paragraph_lines(lines: &[&str], columns: usize, indent: usize, mark: &str) -> String {
    let pad = " ".repeat(indent);
    let mut out = String::new();
    for line in lines {
        for piece in wrap_line(line, columns) {
            push_line(&mut out, &format!("{}{}{}", pad, mark, piece));
        }
    }
    out
}

/// A code box: a rail above and below, the body between them with its own
/// spacing untouched. A line too wide for the screen keeps every character and
/// simply has no right edge drawn, because the box does not claim an end it
/// cannot draw. The width 0 case has no room for a box at all, and the body is
/// shown whole.
fn code_box_lines(lines: &[&str], columns: usize, indent: usize) -> String {
    let pad = " ".repeat(indent);
    let mut out = String::new();
    let widest = lines.iter().map(|line| column_count(line)).max().unwrap_or(0);
    // Two columns of the box belong to the left edge and the space after it.
    let box_columns = widest.saturating_add(2).min(columns);
    if box_columns < 3 {
        for line in lines {
            push_line(&mut out, &format!("{}{}", pad, line));
        }
        return out;
    }
    let rail = BOX_HORIZONTAL.to_string().repeat(box_columns - 2);
    push_line(&mut out, &format!("{}{}{}{}", pad, BOX_TOP_LEFT, rail, BOX_TOP_RIGHT));
    for line in lines {
        let mut row = format!("{}{} {}", pad, BOX_SIDE, line);
        if column_count(line) <= box_columns.saturating_sub(2) {
            row.push_str(&" ".repeat(box_columns - 2 - column_count(line)));
            row.push(BOX_SIDE);
        }
        push_line(&mut out, &row);
    }
    push_line(&mut out, &format!("{}{}{}{}", pad, BOX_BOTTOM_LEFT, rail, BOX_BOTTOM_RIGHT));
    out
}

/// Break one line into the pieces that fit in `columns` columns. Width 0 means
/// the line is not wrapped at all. A word longer than the width is cut at the
/// width and continues on the next line, so nothing is lost.
fn wrap_line(line: &str, columns: usize) -> Vec<String> {
    if columns == 0 || column_count(line) <= columns {
        return vec![line.to_string()];
    }
    let mut out: Vec<String> = Vec::new();
    let mut current = String::new();
    for word in line.split(' ') {
        // A doubled space is kept wherever it falls, even one column past the
        // width: the words stay the reader's and only the break is ours.
        if word.is_empty() {
            if current.is_empty() {
                out.push(" ".to_string());
            } else {
                current.push(' ');
            }
            continue;
        }
        if !current.is_empty() && column_count(&current) + 1 + column_count(word) > columns {
            out.push(std::mem::take(&mut current));
        }
        if current.is_empty() && column_count(word) > columns {
            let mut rest = word;
            while column_count(rest) > columns {
                let head: String = rest.chars().take(columns).collect();
                let taken = head.len();
                out.push(head);
                rest = &rest[taken..];
            }
            current.push_str(rest);
        } else {
            if !current.is_empty() {
                current.push(' ');
            }
            current.push_str(word);
        }
    }
    if !current.is_empty() || out.is_empty() {
        out.push(current);
    }
    out
}

/// The content lines of a span: every line that is not a block line, not a
/// declaration line and not inside a comment. The three judges are strip.rs's
/// and text/comments.rs's, so this is the one place in the package that decides
/// nothing about what syntax is.
fn lines_of_span<'a>(span: Span, buffer: &'a Buffer, comments: &[Comment]) -> Vec<&'a str> {
    let mut out: Vec<&'a str> = Vec::new();
    if span.start == span.end {
        // An empty span names a place and claims no bytes — an error about the
        // whole file says so — so it has no words of its own to show. Without
        // this the walk below would start at line 1 and take it.
        return out;
    }
    let first = buffer.line_at(span.start);
    let last = buffer.line_at(span.end);
    for line in first..=last {
        let text = buffer.line_text(line);
        if is_comment_line(comments, buffer.line_start(line), buffer.line_end(line)) {
            continue;
        }
        if is_block_line(text) || is_declaration_line(text) {
            continue;
        }
        // A blank line is spacing here, exactly as strip.rs judges it; the
        // blank line the rich tier draws between blocks is its own spacing.
        if text.trim().is_empty() {
            continue;
        }
        out.push(text);
    }
    out
}

/// The comments inside a block. A code body has none: its bytes are opaque and
/// a "comment start" word in there is code (rule D), so comments.rs is asked
/// only about the ranges that are readable.
fn readable_comments(block: &Block, buffer: &Buffer) -> Vec<Comment> {
    if block.is_opaque() {
        return Vec::new();
    }
    find_comments_in(buffer, block.span.start, block.span.end)
}

/// True when a block asked to be emphasized. Rule B keeps styling a hint, so
/// this reads the `style:` and `format:` declarations and nothing else: a value
/// nobody registered is ignored rather than guessed at.
fn asks_for_emphasis(block: &Block) -> bool {
    block.declarations.iter().any(|declaration| {
        (declaration.keyword == "style" || declaration.keyword == "format")
            && declaration
                .value
                .split(|c: char| c == ',' || c.is_whitespace())
                .any(|word| EMPHASIS_VALUES.contains(&word))
    })
}

/// The columns of indentation a node at `depth` gets. Nesting deeper than the
/// screen is wide costs no more indent: a narrow screen gets a tall page, not a
/// page whose words are pushed off it.
fn indent_for(depth: usize, width: usize) -> usize {
    depth
        .saturating_mul(BLOCK_INDENT)
        .min(width.saturating_sub(MINIMUM_TEXT_COLUMNS))
}

/// How many columns a piece of text takes. Rule F: a column is counted in
/// characters, never in bytes.
fn column_count(text: &str) -> usize {
    text.chars().count()
}

/// The text a span covers, exactly as the file had it.
fn span_text(span: Span, buffer: &Buffer) -> &str {
    std::str::from_utf8(buffer.slice(span.start, span.end)).unwrap_or("")
}

/// Add one line inside a section.
fn push_line(out: &mut String, line: &str) {
    if !out.is_empty() {
        out.push('\n');
    }
    out.push_str(line);
}

/// Add a block's whole drawing, one blank line before it. The blank line is the
/// only spacing this tier adds; it says "a block ends here" without a word.
fn push_section(out: &mut String, section: &str) {
    if section.is_empty() {
        return;
    }
    if !out.is_empty() {
        out.push('\n');
        out.push('\n');
    }
    out.push_str(section);
}