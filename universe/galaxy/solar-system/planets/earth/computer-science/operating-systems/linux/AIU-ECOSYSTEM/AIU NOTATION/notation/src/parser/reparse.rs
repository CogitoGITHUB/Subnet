//! One job: re-read only the slice of the file an edit touched.
//! Registered in plan/package-tree.org (parser/reparse.rs).
//!
//! TODO.org item 4 ("Robustness", plan/build-order.org step 3): incremental
//! reparse. It is done when an edit in the middle of a file leaves the rest of
//! the file rendered, and the caller is told which elements were rebuilt so
//! the renderer draws only those.
//!
//! How the promise is kept:
//!   * the text is cut at line boundaries — the element the edit starts in and
//!     the element the edit ends in — and only that slice is parsed again,
//!     by partial.rs, which also recovers a break inside it;
//!   * every top-level element outside the slice is carried over as it was.
//!     Its bytes did not change, so its bytes, its declarations and its
//!     children stay the same; only its offsets and line numbers move, by
//!     exactly the edit's byte count and line count;
//!   * the slice is widened to the end of the file when a block ran open inside
//!     it, because an element that crosses the slice's edge is an element the
//!     slice cannot decide; and
//!   * the file-level rule (the title first) is decided once, on the joined
//!     tree, so a spliced file and a re-parsed file say the same thing.

use crate::buffer::Buffer;
use crate::partial;
use crate::parser::{Node, Span, Tree};

/// One edit: the bytes in `start..end` are replaced by `text`. Offsets are
/// bytes (syntax/first-slice-freeze.org, rule F).
#[derive(Debug, Clone)]
pub struct Edit {
    pub start: usize,
    pub end: usize,
    pub text: Vec<u8>,
}

// Edit holds the methods every edit shares, so a caller can ask an edit
// what it changes.
impl Edit {
    /// The same edit with its range pulled inside `0..=len`. An editor may hand
    /// over a range that belonged to an older text; nothing here panics on one.
    pub fn clamped(&self, len: usize) -> Edit {
        let start = self.start.min(len);
        let end = self.end.min(len).max(start);
        Edit { start, end, text: self.text.clone() }
    }

    /// How many bytes the file gains by this edit; negative when it lost bytes.
    pub fn byte_delta(&self, len: usize) -> isize {
        let start = self.start.min(len);
        let end = self.end.min(len).max(start);
        self.text.len() as isize - (end - start) as isize
    }
}

/// What one reparse rebuilt and what it kept. Every number is a 1-based
/// position in `Reparsed::tree`'s node list — the element position the renderer
/// draws at.
#[derive(Debug, Clone)]
pub struct ReparseReport {
    /// Element positions that were read again and may look different.
    pub rebuilt: Vec<usize>,
    /// Element positions carried over untouched.
    pub kept: Vec<usize>,
    /// How many bytes the file gained by the edit.
    pub bytes_added: isize,
}

// ReparseReport holds the methods every report shares, so a caller can
// ask what was rebuilt and what was kept.
impl ReparseReport {
    /// True when element `element` must be drawn again. False means its bytes
    /// did not change, so the renderer may leave it on the screen.
    pub fn needs_redraw(&self, element: usize) -> bool {
        self.rebuilt.contains(&element)
    }
}

/// One reparse: the new text, the new tree, and what had to be rebuilt.
pub struct Reparsed {
    pub buffer: Buffer,
    pub tree: Tree,
    pub report: ReparseReport,
}

/// Reparse `buffer` after `edit`, reusing every element the edit did not touch.
///
/// A `previous` tree that does not belong to `buffer` (its length disagrees) is
/// refused rather than guessed at: the whole file is parsed again instead.
pub fn reparse(previous: &Tree, buffer: &Buffer, edit: &Edit) -> Reparsed {
    if previous.len != buffer.len() {
        return full_reparse(buffer);
    }
    let edit = edit.clamped(buffer.len());
    let new_buffer = with_edit(buffer, &edit);
    let delta = edit.byte_delta(buffer.len());
    let lines = line_delta(buffer, &edit);
    let (from, stop_old) = dirty_window(&previous.nodes, buffer, &edit);

    // A block left open inside the slice reaches the slice's end, which means
    // the element it belongs to continues past it. Widening once is enough:
    // after the body below the end is the end of the file.
    let mut stop = shifted_offset(stop_old, delta);
    let mut window = partial::parse_fragment(&new_buffer, from, stop);
    while stop < new_buffer.len() && partial::block_left_open(&window).is_some() {
        stop = new_buffer.len();
        window = partial::parse_fragment(&new_buffer, from, stop);
    }

    let mut parts: Vec<(Node, bool)> = Vec::with_capacity(previous.nodes.len());
    for node in &previous.nodes {
        match side_of(node, from, stop_old) {
            Side::Before => parts.push((node.clone(), false)),
            Side::After => {
                let mut moved = node.clone();
                move_node(&mut moved, delta, lines);
                parts.push((moved, false));
            }
            Side::Inside | Side::CutAcross => {}
        }
    }
    for node in window.nodes {
        parts.push((node, true));
    }
    parts.sort_by_key(|(node, _)| node.span().start);

    // The title rule looks at the first element of the file, so it is decided
    // again only when the slice reaches the first element.
    if from == 0 {
        let view: Vec<&Node> = parts.iter().map(|(node, _)| node).collect();
        if let Some(error) = partial::title_error(&view) {
            parts.push((Node::Error(error), true));
            parts.sort_by_key(|(node, _)| node.span().start);
        }
    }

    let mut nodes: Vec<Node> = Vec::with_capacity(parts.len());
    let mut rebuilt: Vec<usize> = Vec::new();
    let mut kept: Vec<usize> = Vec::new();
    for (node, was_rebuilt) in parts {
        nodes.push(node);
        if was_rebuilt {
            rebuilt.push(nodes.len());
        } else {
            kept.push(nodes.len());
        }
    }
    let len = new_buffer.len();
    Reparsed {
        buffer: new_buffer,
        tree: Tree { nodes, len },
        report: ReparseReport { rebuilt, kept, bytes_added: delta },
    }
}

/// Parse a whole file with nothing to reuse: the starting point, and the answer
/// whenever a previous tree cannot be trusted. Every element is rebuilt.
pub fn full_reparse(buffer: &Buffer) -> Reparsed {
    let tree = partial::parse_recovering(buffer);
    let rebuilt: Vec<usize> = (1..=tree.nodes.len()).collect();
    Reparsed {
        buffer: Buffer::new(buffer.bytes().to_vec()),
        report: ReparseReport { rebuilt, kept: Vec::new(), bytes_added: 0 },
        tree,
    }
}

/// The bytes with the edit spliced in: nothing before the edit, the new text,
/// nothing after it. Nothing is normalized and no line ending is invented.
fn with_edit(buffer: &Buffer, edit: &Edit) -> Buffer {
    let mut bytes = Vec::with_capacity(buffer.len() + edit.text.len());
    bytes.extend_from_slice(buffer.slice(0, edit.start));
    bytes.extend_from_slice(&edit.text);
    bytes.extend_from_slice(buffer.slice(edit.end, buffer.len()));
    Buffer::new(bytes)
}

/// Where an element sits relative to the slice that was read again.
enum Side {
    /// Ends at or before the slice: its bytes are the same bytes.
    Before,
    /// Starts at or after the slice: its bytes are the same bytes, moved.
    After,
    /// Inside the slice: read again, so the old one is dropped.
    Inside,
    /// Partly inside the slice: the edit reached into it, so it is read again.
    CutAcross,
}

// side_of says which side of an edit a node sits on, so the reparse
// knows what to keep and what to read again.
fn side_of(node: &Node, from: usize, to: usize) -> Side {
    let span = node.span();
    if span.start >= from && span.end <= to {
        return Side::Inside;
    }
    if span.end <= from {
        return Side::Before;
    }
    if span.start >= to {
        return Side::After;
    }
    Side::CutAcross
}

/// The slice to read again, in the old text's offsets: from the start of the
/// element the edit begins in, to the end of the element it ends in. Whole
/// lines, because the syntax is written in lines.
fn dirty_window(nodes: &[Node], buffer: &Buffer, edit: &Edit) -> (usize, usize) {
    let line = buffer.line_at(edit.start);
    let from = match element_start_at(nodes, edit.start) {
        Some(start) => start.min(buffer.line_start(line)),
        None => buffer.line_start(line),
    };
    let last = buffer.line_at(edit.end.saturating_sub(1).max(edit.start));
    let stop = match element_end_at(nodes, edit.end) {
        Some(end) => end.max(buffer.line_end(last)),
        None => buffer.len(),
    };
    (from, stop)
}

/// The start of the element whose bytes cover `offset`.
fn element_start_at(nodes: &[Node], offset: usize) -> Option<usize> {
    nodes
        .iter()
        .filter(|node| {
            let span = node.span();
            span.start <= offset && offset < span.end
        })
        .map(|node| node.span().start)
        .max()
}

/// The end of the element whose bytes cover `offset`, or of the one the offset
/// lands on its last byte of: that element was edited too.
fn element_end_at(nodes: &[Node], offset: usize) -> Option<usize> {
    nodes
        .iter()
        .filter(|node| {
            let span = node.span();
            span.start <= offset && offset <= span.end
        })
        .map(|node| node.span().end)
        .max()
}

/// How many lines the edit added; negative when it removed lines. It moves the
/// line numbers of every element after it, and nothing else.
fn line_delta(buffer: &Buffer, edit: &Edit) -> isize {
    let added = count_line_breaks(&edit.text);
    let removed = count_line_breaks(buffer.slice(edit.start, edit.end));
    added as isize - removed as isize
}

// count_line_breaks counts the newlines in a piece of text, so a line
// number can be moved by the length of an edit.
fn count_line_breaks(bytes: &[u8]) -> usize {
    bytes.iter().filter(|b| **b == b'\n').count()
}

/// Move an element that sat after the edit: the same element, at the same bytes
/// of the new text. `delta` moves byte offsets, `lines` moves line numbers.
fn move_node(node: &mut Node, delta: isize, lines: isize) {
    match node {
        Node::Block(b) => {
            b.span = moved_span(b.span, delta);
            b.line = moved_line(b.line, lines);
            for declaration in &mut b.declarations {
                declaration.span = moved_span(declaration.span, delta);
            }
            for child in &mut b.children {
                move_node(child, delta, lines);
            }
        }
        Node::Error(e) => {
            e.span = moved_span(e.span, delta);
            e.line = moved_line(e.line, lines);
            e.opener_line = e.opener_line.map(|line| moved_line(line, lines));
        }
    }
}

// moved_span moves a span by a change in length, so the bytes a node
// claims still point at the same text.
fn moved_span(span: Span, delta: isize) -> Span {
    Span { start: shifted_offset(span.start, delta), end: shifted_offset(span.end, delta) }
}

// shifted_offset moves a byte offset by a change in length.
fn shifted_offset(offset: usize, delta: isize) -> usize {
    if delta >= 0 {
        offset.saturating_add(delta as usize)
    } else {
        offset.saturating_sub((-delta) as usize)
    }
}

// moved_line moves a line number by a change in the number of lines.
fn moved_line(line: usize, delta: isize) -> usize {
    shifted_offset(line, delta).max(1)
}