//! One job: the layered parser — blocks, nesting, opaque code bodies, and the
//! five registered errors.
//! Registered in plan/package-tree.org (parser/parser.rs).
//!
//! Frozen rules live in syntax/first-slice-freeze.org; this file is their only
//! implementation for the first slice (title, paragraph, code).
//!
//! The block form, which the owner's format rules fix: a block is three lines of
//! shape — the name and `start`, the content on its own line or lines, then
//! the name and `end` again.
//!
//! ```text
//! title start
//! tags: sample
//! The first sample page
//! title end
//! ```
//!
//! The keyword comes first both times, always: `<name> start` and `<name> end`.
//! The owner chose it because it reads the same way to everyone who reads
//! these files — a person, an AI, a `grep`, a CLI. The name is the subject of
//! the line and the word after it says what the line does, so the eye always
//! lands on the same word in the same place.
//!
//! The retired spelling `end <name>` closes nothing and is content like any
//! other line, so a file written the old way reports stray text instead of
//! silently closing a block.
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
pub const BLOCK_NAMES: [&str; 4] = ["title", "paragraph", "code", "heading"];

/// The registered declaration keywords (rule B). They are hints, never meaning.
pub const DECLARATION_KEYWORDS: [&str; 8] =
    ["tags", "language", "style", "theme", "color", "format", "font", "level"];

/// The registered error names (rule E). All are severity error, no off switch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    StrayText,
    MismatchedEnd,
    UnclosedBlock,
    UnknownBlockName,
    MissingTitle,
    BadHeadingLevel,
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
            ErrorKind::BadHeadingLevel => "bad-heading-level",
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
    /// and only an exact matching `code end` line closes it (rule D).
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
    /// "<name> start", with the name exactly as written.
    BlockStart { name: String },
    /// "<name> end", with the name exactly as written.
    BlockEnd { name: String },
    /// "keyword: value" with a registered keyword.
    Declaration { keyword: String, value: String },
    /// Anything else, including a "word:" line with an unregistered keyword, and
    /// the retired "end <name>" spelling, which is content and closes nothing.
    Content,
}

/// Read one line and say what shape it has. Trailing spaces are ignored
/// (rule A); nothing else about the line is touched.
///
/// The three-line block form: the opener is the name and `start`, the closer is
/// the name and `end`, and the content is whatever lines sit between them.
/// The keyword comes first both times: `<name> start` and `<name> end`.
fn shape_of(text: &str) -> LineShape {
    let trimmed = text.trim_end();
    if trimmed.trim().is_empty() {
        return LineShape::Blank;
    }
    let parts: Vec<&str> = trimmed.split_whitespace().collect();
    if parts.len() == 2 {
        if parts[1] == "start" {
            return LineShape::BlockStart { name: parts[0].to_string() };
        }
        if parts[1] == "end" {
            return LineShape::BlockEnd { name: parts[0].to_string() };
        }
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

/// True when the line opens a block of that name and of no other: it is the
/// two words `<name> start` and nothing else. Spelled out here because the
/// recovery in partial/ needs it and `shape_of` is private to this file.
pub fn opens_block(line: &str, name: &str) -> bool {
    match shape_of(line) {
        LineShape::BlockStart { name: written } => written == name,
        _ => false,
    }
}

/// True when the line closes a block of that name and of no other: it is the
/// two words `<name> end` and nothing else.
pub fn closes_block(line: &str, name: &str) -> bool {
    match shape_of(line) {
        LineShape::BlockEnd { name: written } => written == name,
        _ => false,
    }
}

/// True when the line opens one of the Tier 1 blocks: `<name> start` with a
/// registered name. Used by the recovery to find where a broken file reads
/// again, so the two never disagree about what an opener is.
pub fn opens_registered_block(line: &str) -> bool {
    match shape_of(line) {
        LineShape::BlockStart { ref name } => is_block_name(name),
        _ => false,
    }
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

        // A code block's body is opaque (rule D): nothing inside it is read as
        // notation, and only an exact matching `code end` line closes it. A line
        // that looks like a start line is content, so it opens nothing.
        if let Some(inner) = open.last() {
            if inner.is_opaque() {
                match shape_of(text) {
                    LineShape::BlockEnd { ref name } if *name == inner.name => {
                        close_block(&mut open, &mut top, name, span, line);
                    }
                    // every other line, including a "<name> start" line and a
                    // mismatched end line, is content of the opaque body
                    _ => {}
                }
                continue;
            }
        }

        match shape_of(text) {
            LineShape::Blank => {
                // Blank lines between blocks carry no meaning (rule b).
            }
            LineShape::BlockStart { name } => {
                if !is_block_name(&name) {
                    push_error(&mut open, &mut top, unknown_name(span, line, &name));
                } else {
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
                    // A heading carries its depth in a `level:` declaration. A
                    // level that cannot be read is reported on the declaration
                    // line itself, and the heading falls back to level 1 so the
                    // numbering never counts a level it could not read.
                    if name == "heading" {
                        for declaration in &declarations {
                            if declaration.keyword == "level"
                                && heading_level(std::slice::from_ref(declaration)).is_none()
                            {
                                push_error(
                                    &mut open,
                                    &mut top,
                                    bad_heading_level(
                                        declaration.span,
                                        buffer.line_at(declaration.span.start),
                                        &declaration.value,
                                    ),
                                );
                            }
                        }
                    }
                    open.push(Block {
                        name,
                        span,
                        line,
                        declarations,
                        children: Vec::new(),
                    });
                }
            }
            LineShape::BlockEnd { name } => {
                if !is_block_name(&name) {
                    push_error(&mut open, &mut top, unknown_name(span, line, &name));
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
                what_to_do: format!("add its matching \"end {}\" line", name),
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
                what: format!("\"end {}\" closes nothing: no block is open", name),
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
                        "\"end {}\" does not match the innermost open \"{}\" block",
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
        what_to_do: "use one of title, paragraph, code, heading".to_string(),
    }
}

/// The level a heading block declares, or the default level 1.
///
/// A heading carries its depth in a `level:` declaration, so the block name
/// stays one name instead of one name per depth. A heading with no `level:`
/// line is a first-level heading. A `level:` value that is not a whole number
/// of 1 or more is a `bad-heading-level` error and the block falls back to
/// level 1, so the numbering never counts a level it could not read.
pub fn heading_level(declarations: &[Declaration]) -> Option<u32> {
    for declaration in declarations {
        if declaration.keyword == "level" {
            return match declaration.value.trim().parse::<u32>() {
                Ok(level) if level >= 1 => Some(level),
                _ => None,
            };
        }
    }
    None
}

/// The error a heading block gets when its `level:` value cannot be read.
fn bad_heading_level(span: Span, line: usize, value: &str) -> ErrorNode {
    ErrorNode {
        kind: ErrorKind::BadHeadingLevel,
        span,
        line,
        opener_line: None,
        what: format!("the heading level \"{}\" is not a whole number of 1 or more", value),
        what_to_do: "write the level as a number, for example \"level: 2\"".to_string(),
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

#[cfg(test)]
mod tests {
    //! The block form, exercised on text and not on a hand-built tree: a page
    //! written the way the owner's format rules write it must come back as the
    //! blocks it says it is, with the content as the body and nothing invented.
    use super::*;
    use crate::buffer::Buffer;

    /// A page in the new form: three-line blocks, content on its own lines.
    const VALID_PAGE: &str = "\
title start
tags: sample
A valid page
title end

paragraph start
The first line of the body.
The second line of the body.
paragraph end
";

    /// A page whose code body holds lines that look like marks. Nothing in there
    /// is parsed (rule D), so both stay content.
    const OPAQUE_PAGE: &str = "\
title start
A page with a code body
title end

code start
language: text
def example():
    return 1
code start
paragraph end
code end
";

    fn buffer_of(text: &str) -> Buffer {
        Buffer::from_text(text)
    }

    fn top_blocks(tree: &Tree) -> Vec<&Block> {
        tree.nodes
            .iter()
            .filter_map(|node| match node {
                Node::Block(b) => Some(b),
                Node::Error(_) => None,
            })
            .collect()
    }

    fn block_named<'a>(tree: &'a Tree, name: &str) -> &'a Block {
        top_blocks(tree)
            .into_iter()
            .find(|b| b.name == name)
            .unwrap_or_else(|| panic!("no {} block in the tree", name))
    }

    fn error_kinds(tree: &Tree) -> Vec<ErrorKind> {
        tree.errors().into_iter().map(|e| e.kind).collect()
    }

    /// The body lines of a block: what sits between the declaration run and the
    /// closing line, with the blank spacing dropped. This is the reader test —
    /// the words in the file are the words the tree kept.
    fn body_lines(buffer: &Buffer, block: &Block) -> Vec<String> {
        let first = block.line + 1 + block.declarations.len();
        let last = buffer.line_at(block.span.end.saturating_sub(1).max(block.span.start));
        let mut out: Vec<String> = Vec::new();
        for line in first..last {
            let text = buffer.line_text(line);
            if text.trim().is_empty() {
                continue;
            }
            out.push(text.to_string());
        }
        out
    }

    #[test]
    fn a_valid_page_parses_to_the_expected_kinds() {
        let buffer = buffer_of(VALID_PAGE);
        let tree = parse(&buffer);
        let names: Vec<&str> = top_blocks(&tree).iter().map(|b| b.name.as_str()).collect();
        assert_eq!(names, vec!["title", "paragraph"]);
        assert_eq!(error_kinds(&tree), Vec::<ErrorKind>::new());
        assert!(tree.round_trips(&buffer));
    }

    #[test]
    fn content_lines_are_the_body() {
        let buffer = buffer_of(VALID_PAGE);
        let tree = parse(&buffer);
        let title = block_named(&tree, "title");
        assert_eq!(body_lines(&buffer, title), vec!["A valid page".to_string()]);
        // The declaration run is a hint on the block, not part of its body.
        assert_eq!(title.declarations.len(), 1);
        assert_eq!(title.declarations[0].keyword, "tags");
        assert_eq!(title.declarations[0].value, "sample");
        let paragraph = block_named(&tree, "paragraph");
        assert_eq!(
            body_lines(&buffer, paragraph),
            vec!["The first line of the body.".to_string(), "The second line of the body.".to_string()]
        );
        // A body line is not an element: the tree has no node kind for loose
        // text (rule b), so neither block has children.
        assert!(title.children.is_empty());
        assert!(paragraph.children.is_empty());
    }

    #[test]
    fn end_name_closes_its_block() {
        let buffer = buffer_of(VALID_PAGE);
        let tree = parse(&buffer);
        let title = block_named(&tree, "title");
        assert_eq!(title.span.start, buffer.line_start(1));
        // The span ends at the end of the "title end" line, not one byte later.
        assert_eq!(title.span.end, buffer.line_end(4));
        assert_eq!(buffer.line_text(4), "title end");
        // The closer belongs to the block it closes: no error, no second node.
        assert_eq!(tree.nodes.len(), 2);
    }

    #[test]
    fn the_retired_end_name_spelling_closes_nothing() {
        let text = "title start\nA page\nend title\n";
        let buffer = buffer_of(text);
        let tree = parse(&buffer);
        // "end title" is a content line, so the title runs to the end of the
        // file and is reported as unclosed.
        let kinds = error_kinds(&tree);
        assert!(kinds.contains(&ErrorKind::UnclosedBlock), "kinds were {:?}", kinds);
        assert_eq!(top_blocks(&tree).len(), 1);
        assert_eq!(top_blocks(&tree)[0].span.end, buffer.len());
    }

    #[test]
    fn an_unclosed_block_is_recovered_as_an_error_node_that_keeps_its_children() {
        // A title, then a paragraph that opens a code block and never closes.
        let text = "title start\nA page\ntitle end\n\nparagraph start\nstill open\ncode start\nlanguage: text\ncode end\n";
        let buffer = buffer_of(text);
        let tree = parse(&buffer);
        let paragraph = block_named(&tree, "paragraph");
        assert_eq!(paragraph.span.end, buffer.len());
        let nested: Vec<&str> = paragraph.children.iter().map(|n| match n {
            Node::Block(b) => b.name.as_str(),
            Node::Error(_) => "",
        }).collect();
        assert_eq!(nested, vec!["code"]);
        let errors = tree.errors();
        let unclosed: Vec<&ErrorNode> =
            errors.iter().filter(|e| e.kind == ErrorKind::UnclosedBlock).copied().collect();
        assert_eq!(unclosed.len(), 1);
        // An empty span: the error names a place and claims no bytes, so the
        // file still prints back byte for byte (rule F).
        assert_eq!(unclosed[0].span.start, unclosed[0].span.end);
        assert!(unclosed[0].what_to_do.contains("paragraph end"));
        assert!(tree.round_trips(&buffer));
    }

    #[test]
    fn a_code_body_stays_opaque() {
        let buffer = buffer_of(OPAQUE_PAGE);
        let tree = parse(&buffer);
        assert_eq!(error_kinds(&tree), Vec::<ErrorKind>::new());
        let code = block_named(&tree, "code");
        assert!(code.is_opaque());
        assert_eq!(
            body_lines(&buffer, code),
            vec![
                "def example():".to_string(),
                "    return 1".to_string(),
                // A start line inside the body opens nothing.
                "code start".to_string(),
                // A mismatched end line inside the body closes nothing.
                "paragraph end".to_string(),
            ]
        );
        assert_eq!(code.span.end, buffer.line_end(11));
        assert!(tree.round_trips(&buffer));
    }

    #[test]
    fn only_end_code_closes_a_code_body() {
        // "title end" is not "code end": the code block runs on and the title
        // that wrote it is still the innermost block that can be closed.
        let text = "title start\nA page\ncode start\ntitle end\n";
        let buffer = buffer_of(text);
        let tree = parse(&buffer);
        let kinds = error_kinds(&tree);
        assert!(kinds.contains(&ErrorKind::UnclosedBlock), "kinds were {:?}", kinds);
    }

    #[test]
    fn an_unregistered_name_is_reported_on_both_spellings() {
        for line in ["figure start", "figure end"] {
            let text = format!("title start\nA page\ntitle end\n{}\n", line);
            let tree = parse(&buffer_of(&text));
            let kinds = error_kinds(&tree);
            assert!(
                kinds.contains(&ErrorKind::UnknownBlockName),
                "{} gave {:?}",
                line,
                kinds
            );
        }
    }

    #[test]
    fn the_opener_and_closer_tests_are_the_ones_the_recovery_asks_for() {
        assert!(opens_block("code start", "code"));
        assert!(opens_registered_block("code start"));
        assert!(!opens_registered_block("code end"));
        assert!(closes_block("code end", "code"));
        assert!(!closes_block("code start", "code"));
        // Trailing spaces are ignored (rule A); anything else on the line is
        // content, so neither test fires.
        assert!(closes_block("code end   ", "code"));
        assert!(!closes_block("code end because", "code"));
        assert!(!opens_block("code end", "code"));
    }
}
