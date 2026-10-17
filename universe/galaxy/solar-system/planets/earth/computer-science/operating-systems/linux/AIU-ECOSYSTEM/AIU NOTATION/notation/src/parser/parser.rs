//! One job: the layered parser — blocks, nesting, opaque code bodies, and the
//! five registered errors.
//! Registered in plan/package-tree.org (parser/parser.rs).
//!
//! Frozen rules live in syntax/first-slice-freeze.org; this file is their only
//! implementation for the first slice (title, paragraph, code).
//!
//! Two promises it keeps:
//!   * the meaning tree has no node kind for loose text — only blocks and
//!     error nodes (rule b), and
//!   * the tree prints back to the identical file bytes (rule F). Nothing is
//!     re-generated: every node carries the byte span it came from and
//!     `Tree::print_back` concatenates those spans, so the spans must tile the
//!     file exactly. Errors that belong to the whole file therefore carry an
//!     empty span and add no bytes.

use crate::buffer::Buffer;
use crate::positions::{line_col_to_offset, offset_to_line_col, LineCol};

/// The Tier 1 block names (rule A). Anything else on a block line is an error.
pub const BLOCK_NAMES: [&str; 3] = ["title", "paragraph", "code"];

/// The registered declaration keywords (rule B). They are hints, never meaning.
pub const DECLARATION_KEYWORDS: [&str; 7] =
    ["tags", "language", "style", "theme", "color", "format", "font"];

/// The five registered error names (rule E). All are severity error, no off switch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    StrayText,
    MismatchedEnd,
    UnclosedBlock,
    UnknownBlockName,
    MissingTitle,
}

impl ErrorKind {
    /// The name as it is written in a diagnosis and in the tree.
    pub fn name(self) -> &'static str {
        match self {
            ErrorKind::StrayText => "stray-text",
            ErrorKind::MismatchedEnd => "mismatched-end",
            ErrorKind::UnclosedBlock => "unclosed-block",
            ErrorKind::UnknownBlockName => "unknown-block-name",
            ErrorKind::MissingTitle => "missing-title",
        }
    }
}

/// A byte span in the file, half-open: start inclusive, end exclusive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

impl Span {
    /// An empty span: it names a place without claiming any bytes.
    pub fn empty(at: usize) -> Span {
        Span { start: at, end: at }
    }
}

/// One declaration line: a registered keyword and its value, stored as a hint.
#[derive(Debug, Clone)]
pub struct Declaration {
    pub keyword: String,
    pub value: String,
    pub span: Span,
}

/// One block: what it is, where it starts and ends, what it declares, and what
/// sits inside it. `span` covers the whole block, start line to end line.
#[derive(Debug, Clone)]
pub struct Block {
    pub name: String,
    pub span: Span,
    pub line: usize,
    pub declarations: Vec<Declaration>,
    pub children: Vec<Node>,
}

impl Block {
    /// The code block's body is opaque: nothing inside it is read as notation,
    /// and only an exact matching end line closes it (rule D).
    pub fn is_opaque(&self) -> bool {
        self.name == "code"
    }
}

/// An error node. It keeps the offending text untouched and says what to do.
#[derive(Debug, Clone)]
pub struct ErrorNode {
    pub kind: ErrorKind,
    pub span: Span,
    pub line: usize,
    /// The line of the opener, when the error is about a block that was opened.
    pub opener_line: Option<usize>,
    pub what: String,
    pub what_to_do: String,
}

/// The tree: blocks and error nodes, and nothing else (rule b).
#[derive(Debug, Clone)]
pub enum Node {
    Block(Block),
    Error(ErrorNode),
}

impl Node {
    pub fn span(&self) -> Span {
        match self {
            Node::Block(b) => b.span,
            Node::Error(e) => e.span,
        }
    }
}

/// One parsed file.
#[derive(Debug, Clone)]
pub struct Tree {
    pub nodes: Vec<Node>,
    pub len: usize,
}

impl Tree {
    /// Print the file back: the node spans in order, and the bytes between
    /// them, give the input byte for byte.
    pub fn print_back(&self, buffer: &Buffer) -> Vec<u8> {
        let mut out: Vec<u8> = Vec::with_capacity(self.len);
        let mut cursor = 0usize;
        for node in &self.nodes {
            let span = node.span();
            if span.start > cursor {
                out.extend_from_slice(buffer.slice(cursor, span.start));
            }
            out.extend_from_slice(buffer.slice(span.start, span.end));
            cursor = span.end;
        }
        if cursor < self.len {
            out.extend_from_slice(buffer.slice(cursor, self.len));
        }
        out
    }

    /// True when the tree prints back to the bytes it was built from.
    pub fn round_trips(&self, buffer: &Buffer) -> bool {
        self.print_back(buffer) == buffer.bytes()
    }

    /// Every error node in the file, in the order they appear.
    pub fn errors(&self) -> Vec<&ErrorNode> {
        let mut out: Vec<&ErrorNode> = Vec::new();
        for node in &self.nodes {
            collect_errors(node, &mut out);
        }
        out
    }
}

fn collect_errors<'a>(node: &'a Node, out: &mut Vec<&'a ErrorNode>) {
    match node {
        Node::Error(e) => out.push(e),
        Node::Block(b) => {
            for child in &b.children {
                collect_errors(child, out);
            }
        }
    }
}

/// What a line is, before any rule is applied.
enum LineShape {
    Blank,
    /// "<name> start" or "<name> end", with the name exactly as written.
    BlockLine { name: String, is_start: bool },
    /// "keyword: value" with a registered keyword.
    Declaration { keyword: String, value: String },
    /// Anything else, including a "word:" line with an unregistered keyword.
    Content,
}

/// Read one line and say what shape it has. Trailing spaces are ignored
/// (rule A); nothing else about the line is touched.
fn shape_of(text: &str) -> LineShape {
    let trimmed = text.trim_end();
    if trimmed.trim().is_empty() {
        return LineShape::Blank;
    }
    let parts: Vec<&str> = trimmed.split_whitespace().collect();
    if parts.len() == 2 && (parts[1] == "start" || parts[1] == "end") {
        return LineShape::BlockLine {
            name: parts[0].to_string(),
            is_start: parts[1] == "start",
        };
    }
    if let Some(colon) = trimmed.find(':') {
        let keyword = trimmed[..colon].trim();
        let value = trimmed[colon + 1..].trim();
        if !keyword.is_empty() && DECLARATION_KEYWORDS.contains(&keyword) {
            return LineShape::Declaration {
                keyword: keyword.to_string(),
                value: value.to_string(),
            };
        }
    }
    LineShape::Content
}

fn is_block_name(name: &str) -> bool {
    BLOCK_NAMES.contains(&name)
}

/// Parse one buffer into a tree.
pub fn parse(buffer: &Buffer) -> Tree {
    let line_count = buffer.line_count();
    let mut top: Vec<Node> = Vec::new();
    // The open blocks, innermost last (rule c).
    let mut open: Vec<Block> = Vec::new();
    let mut saw_block = false;
    let mut first_is_title = false;

    for line in 1..=line_count {
        let span = Span { start: buffer.line_start(line), end: buffer.line_end(line) };
        let text = buffer.line_text(line);

        match shape_of(text) {
            LineShape::Blank => {
                // Blank lines between blocks carry no meaning (rule b).
            }
            LineShape::BlockLine { name, is_start } => {
                if !is_block_name(&name) {
                    push_error(&mut open, &mut top, unknown_name(span, line, &name));
                } else if is_start {
                    let mut declarations = Vec::new();
                    let mut scan = line + 1;
                    // Consecutive declaration lines straight under the start
                    // line (rule B). Any other line ends the run.
                    while scan <= line_count {
                        match shape_of(buffer.line_text(scan)) {
                            LineShape::Declaration { keyword, value } => {
                                declarations.push(Declaration {
                                    keyword,
                                    value,
                                    span: Span {
                                        start: buffer.line_start(scan),
                                        end: buffer.line_end(scan),
                                    },
                                });
                                scan += 1;
                            }
                            _ => break,
                        }
                    }
                    if !saw_block {
                        saw_block = true;
                        first_is_title = name == "title";
                    }
                    open.push(Block {
                        name,
                        span,
                        line,
                        declarations,
                        children: Vec::new(),
                    });
                } else {
                    close_block(&mut open, &mut top, &name, span, line);
                }
            }
            LineShape::Content | LineShape::Declaration { .. } => {
                // Inside a block a line is content, whatever it looks like.
                // Outside a block there is no block to be content of, so the
                // line is stray text and stays exactly where it is (rule b).
                if open.is_empty() {
                    push_error(&mut open, &mut top, stray(span, line));
                }
            }
        }
    }

    // A block still open at the end of the file (rule E). The block keeps its
    // bytes; the error carries an empty span so the file still tiles.
    while let Some(mut block) = open.pop() {
        let opener = block.line;
        block.span.end = buffer.len();
        let name = block.name.clone();
        push_error(
            &mut open,
            &mut top,
            ErrorNode {
                kind: ErrorKind::UnclosedBlock,
                span: Span::empty(buffer.len()),
                line: buffer.len().saturating_sub(1).max(1),
                opener_line: Some(opener),
                what: format!("block \"{}\" was opened at line {} and never closed", name, opener),
                what_to_do: format!("add its matching \"{} end\" line", name),
            },
        );
        attach(&mut open, &mut top, Node::Block(block));
    }

    // The title must be the first block of the file (rule C).
    if !saw_block || !first_is_title {
        push_error(
            &mut open,
            &mut top,
            ErrorNode {
                kind: ErrorKind::MissingTitle,
                span: Span::empty(0),
                line: 1,
                opener_line: None,
                what: if saw_block {
                    "the first block of the file is not a title".to_string()
                } else {
                    "the file has no block at all, so it has no title".to_string()
                },
                what_to_do: "start the file with \"title start\"".to_string(),
            },
        );
    }

    top.sort_by_key(|n| n.span().start);
    Tree { nodes: top, len: buffer.len() }
}

/// Put an error where it belongs: inside the innermost open block, or at the
/// top of the file when nothing is open.
fn push_error(open: &mut Vec<Block>, top: &mut Vec<Node>, error: ErrorNode) {
    let node = Node::Error(error);
    attach(open, top, node);
}

/// Close the innermost open block into the tree, under whatever is open above
/// it once it is closed.
fn attach(open: &mut Vec<Block>, top: &mut Vec<Node>, node: Node) {
    match open.last_mut() {
        Some(parent) => parent.children.push(node),
        None => top.push(node),
    }
}

fn close_block(open: &mut Vec<Block>, top: &mut Vec<Node>, name: &str, span: Span, line: usize) {
    match open.last() {
        None => push_error(
            open,
            top,
            ErrorNode {
                kind: ErrorKind::MismatchedEnd,
                span,
                line,
                opener_line: None,
                what: format!("\"{} end\" closes nothing: no block is open", name),
                what_to_do: "remove the line, or open the block it was meant to close".to_string(),
            },
        ),
        Some(block) if block.name == name => {
            let mut finished = open.pop().expect("the innermost block is open");
            finished.span.end = span.end;
            attach(open, top, Node::Block(finished));
        }
        Some(block) => {
            let inner = block.name.clone();
            let opener = block.line;
            push_error(
                open,
                top,
                ErrorNode {
                    kind: ErrorKind::MismatchedEnd,
                    span,
                    line,
                    opener_line: Some(opener),
                    what: format!(
                        "\"{} end\" does not match the innermost open \"{}\" block",
                        name, inner
                    ),
                    what_to_do: format!("close the open \"{}\" block first", inner),
                },
            );
        }
    }
}

fn stray(span: Span, line: usize) -> ErrorNode {
    ErrorNode {
        kind: ErrorKind::StrayText,
        span,
        line,
        opener_line: None,
        what: "text outside any named block".to_string(),
        what_to_do: "put the text inside a \"<name> start\" / \"<name> end\" block".to_string(),
    }
}

fn unknown_name(span: Span, line: usize, name: &str) -> ErrorNode {
    ErrorNode {
        kind: ErrorKind::UnknownBlockName,
        span,
        line,
        opener_line: None,
        what: format!("\"{}\" is not a Tier 1 block name", name),
        what_to_do: "use one of title, paragraph, code".to_string(),
    }
}

/// The 1-based line and character column of a byte offset, for a diagnosis.
pub fn place_of(buffer: &Buffer, offset: usize) -> LineCol {
    offset_to_line_col(buffer, offset)
}

/// The byte offset of a line and character column, for a diagnosis.
pub fn offset_of(buffer: &Buffer, line: usize, column: usize) -> usize {
    line_col_to_offset(buffer, line, column)
}