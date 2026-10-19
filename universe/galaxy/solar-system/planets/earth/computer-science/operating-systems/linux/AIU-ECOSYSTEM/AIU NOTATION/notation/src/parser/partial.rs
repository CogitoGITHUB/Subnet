//! One job: recovery — a broken element falls back to an error node and the
//! text after it keeps parsing.
//! Registered in plan/package-tree.org (parser/partial.rs).
//!
//! TODO.org item 4 ("Robustness", plan/build-order.org step 3): incremental
//! reparse and recovery. This file is the recovery half; reparse.rs is the
//! incremental half and calls into it here.
//!
//! Three promises it keeps, for any bytes at all:
//!   * it never panics — every read goes through Buffer, whose accessors clamp,
//!   * it never loses a byte — the tree still prints back to the text it was
//!     built from (rule F), because every byte is inside a node span or in the
//!     gap between two of them, and
//!   * a break never swallows the rest of the file — the broken element becomes
//!     the error node the model already has, and the text after it is parsed
//!     again as its own elements.
//!
//! Where the break goes: a block that was opened and never closed runs to the
//! end of the text in parser.rs. That is right for a `code` block, whose body
//! is opaque (rule D), and wrong for any other block, whose text after the
//! break is notation again. So recovery looks for the first line inside the
//! block where the file becomes a shape the parser can read again — a Tier 1
//! `<name> start` line — cuts there, and puts the error node at the cut.

use crate::buffer::Buffer;
use crate::parser::{parse, Block, ErrorKind, ErrorNode, Node, Span, Tree, BLOCK_NAMES};

/// Parse a whole file and recover where the parser could not: every element
/// that parsed cleanly stays, the broken one becomes an error node, and the
/// text after the break is still parsed.
///
/// The title rule is decided here, once, on the recovered tree — never on a
/// slice, and never on the tree as it stood before the recovery cut it.
pub fn parse_recovering(buffer: &Buffer) -> Tree {
    let mut tree = recover(&parse(buffer), buffer);
    tree.nodes.retain(|node| !is_the_file_title_rule(node));
    let view: Vec<&Node> = tree.nodes.iter().collect();
    if let Some(error) = title_error(&view) {
        tree.nodes.push(Node::Error(error));
        tree.nodes.sort_by_key(|node| node.span().start);
    }
    tree
}

/// Parse one slice of a bigger text as if it stood alone, for a caller that is
/// editing a window rather than a file.
///
/// Spans come back in whole-file byte offsets, so a slice can be joined to its
/// neighbours without moving anything again. The rules that belong to the whole
/// file are left out (they are decided once, on the joined text, by
/// `title_error`); recovery still runs, so a break inside the slice is still
/// a break. `len` is the whole text's length, so the tree is printed against
/// the whole text.
pub fn parse_fragment(buffer: &Buffer, from: usize, to: usize) -> Tree {
    let from = from.min(buffer.len());
    let to = to.min(buffer.len()).max(from);
    let slice = Buffer::new(buffer.slice(from, to).to_vec());
    let mut tree = recover(&parse(&slice), &slice);
    for node in &mut tree.nodes {
        move_node(node, from);
    }
    tree.nodes.retain(|node| !is_the_file_title_rule(node));
    tree.len = buffer.len();
    tree
}

/// The byte where a block ran to the end of the text it was given without
/// closing, or None when every block closed. A caller that parsed a slice asks
/// this first: Some means the slice cut an element in half, so the slice must
/// reach the end of the file before its answer can be trusted.
pub fn block_left_open(tree: &Tree) -> Option<usize> {
    tree.nodes.iter().find_map(node_left_open)
}

// node_left_open gives the node that was opened and never closed, so the
// recovery can point at the block that was left open.
fn node_left_open(node: &Node) -> Option<usize> {
    match node {
        Node::Error(e) if e.kind == ErrorKind::UnclosedBlock => Some(e.span.start),
        Node::Block(b) => b.children.iter().find_map(node_left_open),
        _ => None,
    }
}

/// The rule that belongs to the whole file and not to one slice: the title must
/// be the first block (rule C). None when the tree already starts with a title.
///
/// parser.rs owns the rule and writes the same two sentences for a whole-file
/// parse; they are repeated here so a joined tree and a re-parsed whole file
/// say one thing. Change both together.
pub fn title_error(nodes: &[&Node]) -> Option<ErrorNode> {
    let mut first = None;
    for node in nodes {
        if let Node::Block(b) = node {
            first = Some(b.name.as_str());
            break;
        }
    }
    let what = match first {
        Some("title") => return None,
        Some(_) => "the first block of the file is not a title".to_string(),
        None => "the file has no block at all, so it has no title".to_string(),
    };
    Some(ErrorNode {
        kind: ErrorKind::MissingTitle,
        span: Span::empty(0),
        line: 1,
        opener_line: None,
        what,
        what_to_do: "start the file with \"title start\"".to_string(),
    })
}

// is_the_file_title_rule says whether a node is the title of the file,
// which is the one block a page must open with.
fn is_the_file_title_rule(node: &Node) -> bool {
    matches!(node, Node::Error(e) if e.kind == ErrorKind::MissingTitle)
}

/// Walk the top level once. An unclosed block that has a line after which the
/// file reads again is cut at that line; the tail is parsed again here and the
/// remaining old nodes are dropped, because every one of them was inside the
/// block that ran on.
fn recover(tree: &Tree, buffer: &Buffer) -> Tree {
    let mut out: Vec<Node> = Vec::with_capacity(tree.nodes.len());
    for node in &tree.nodes {
        match node {
            Node::Block(b) if !b.is_opaque() && !ends_with_its_end_line(b, buffer) => {
                let line = match break_line_of(b, buffer) {
                    None => {
                        out.push(node.clone());
                        continue;
                    }
                    Some(line) => line,
                };
                let cut = buffer.line_start(line);
                let mut head = b.clone();
                head.span.end = cut;
                out.push(Node::Block(head));
                out.push(Node::Error(cut_error(b, line, cut)));
                out.extend(parse_fragment(buffer, cut, buffer.len()).nodes);
                return Tree { nodes: out, len: buffer.len() };
            }
            _ => {
    if let Node::Block(b) = node {
        let unclosed = tree.nodes.iter().any(|n| {
            matches!(n, Node::Error(e) if e.kind == ErrorKind::UnclosedBlock && e.opener_line == Some(b.line))
        });
        if unclosed {
            let mut b = b.clone();
            let end = b.span.end;
            b.children.retain(|child| {
                match child {
                    Node::Block(cb) => cb.span.end < end.saturating_sub(1) || cb.name == "code",
                    _ => true,
                }
            });
            out.push(Node::Block(b));
            continue;
        }
    }
    out.push(node.clone())
}
        }
    }
    Tree { nodes: out, len: buffer.len() }
}

/// True when the block's last line is its own "<name> end" line, which is how a
/// closed block differs from one that ran to the end of the text.
fn ends_with_its_end_line(block: &Block, buffer: &Buffer) -> bool {
    let last = block.span.end.saturating_sub(1).max(block.span.start);
    let text = buffer.line_text(buffer.line_at(last));
    match text.trim_end().strip_prefix(block.name.as_str()) {
        Some(rest) => rest.trim() == "end",
        None => false,
    }
}

/// The first line inside an unclosed block that opens a Tier 1 block again:
/// the line where the file becomes readable. None when there is none, and then
/// the block legitimately runs to the end of the text.
fn break_line_of(block: &Block, buffer: &Buffer) -> Option<usize> {
    let first = block.line + 1 + block.declarations.len();
    for line in first..=buffer.line_count() {
        if opens_a_registered_block(buffer.line_text(line)) {
            return Some(line);
        }
    }
    None
}

/// The block-line test of parser.rs, repeated because `shape_of` is private and
/// parser/ may not reach down into rendering/ for it: two words, the second
/// "start", and a Tier 1 name.
fn opens_a_registered_block(line: &str) -> bool {
    let parts: Vec<&str> = line.trim_end().split_whitespace().collect();
    parts.len() == 2 && parts[1] == "start" && BLOCK_NAMES.contains(&parts[0])
}

/// The error node at the cut. It carries an empty span, like the errors that
/// belong to a whole block, so the bytes of the break are still the file's own
/// and the tree still prints back (rule F). The text after the cut is not this
/// node's to keep: it is parsed again as its own elements.
fn cut_error(block: &Block, line: usize, cut: usize) -> ErrorNode {
    let name = block.name.as_str();
    ErrorNode {
        kind: ErrorKind::UnclosedBlock,
        span: Span::empty(cut),
        line,
        opener_line: Some(block.line),
        what: format!("block \"{}\" was opened at line {} and never closed", name, block.line),
        what_to_do: format!("close it with a \"{} end\" line, or move line {}", name, line),
    }
}

/// Move every span in a tree by whole-file bytes, after it was parsed as a
/// slice that started at `offset`.
fn move_node(node: &mut Node, offset: usize) {
    match node {
        Node::Block(b) => {
            b.span.start += offset;
            b.span.end += offset;
            for d in &mut b.declarations {
                d.span.start += offset;
                d.span.end += offset;
            }
            for child in &mut b.children {
                move_node(child, offset);
            }
        }
        Node::Error(e) => {
            e.span.start += offset;
            e.span.end += offset;
        }
    }
}