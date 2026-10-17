//! One job: print the parse tree as a plain text document — the
//! `parse-tree-document` shape frozen in join/INDEX.org.
//! Registered in plan/package-tree.org (join/rust-exports.rs).
//!
//! This is the only function the Racket side may call, and it depends on no
//! Racket at all: text in, document text out. How the document is carried — a
//! call or a subprocess — is still open and is not decided here.
//!
//! The shape, in one place so the Rust side and join/INDEX.org cannot drift:
//!   NOTATION-DOCUMENT 1
//!   file "<path>"
//!   node block <name> <startLine> <startOffset> <endLine> <endOffset> <depth>
//!   decl <keyword> "<value>" <line> <offset>
//!   error <kind> <line> <offset> <openerLine> "<what>" "<whatToDo>"
//!   end
//! Lines are 1-based, offsets are byte offsets, and every quoted field keeps
//! its spaces and doubles any quote inside it.

use crate::buffer::Buffer;
use crate::parser::{parse, Node};

/// Parse `text` and return the document. The file name is carried in the
/// document's second line, so every line an error names points at a file.
pub fn parse_document(file: &str, text: &str) -> String {
    let buffer = Buffer::from_text(text);
    let tree = parse(&buffer);
    let mut out = String::new();
    out.push_str("NOTATION-DOCUMENT 1\n");
    out.push_str(&format!("file {}\n", quote(file)));
    for node in &tree.nodes {
        write_node(&mut out, &buffer, node, 0);
    }
    out.push_str("end\n");
    out
}

/// A quoted field: spaces kept, a double quote inside written twice.
fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        if c == '"' {
            out.push('"');
        }
        out.push(c);
    }
    out.push('"');
    out
}

/// Write one entry and everything inside it. The depth is how many blocks are
/// open above it, so a reader sees the shape without counting.
fn write_node(out: &mut String, buffer: &Buffer, node: &Node, depth: usize) {
    match node {
        Node::Block(block) => {
            out.push_str(&format!(
                "node block {} {} {} {} {} {}\n",
                block.name,
                block.line,
                block.span.start,
                buffer.line_at(block.span.end),
                block.span.end,
                depth
            ));
            for decl in &block.declarations {
                out.push_str(&format!(
                    "decl {} {} {} {}\n",
                    decl.keyword,
                    quote(&decl.value),
                    buffer.line_at(decl.span.start),
                    decl.span.start
                ));
            }
            for child in &block.children {
                write_node(out, buffer, child, depth + 1);
            }
        }
        Node::Error(error) => {
            let opener = error.opener_line.unwrap_or(0);
            out.push_str(&format!(
                "error {} {} {} {} {} {}\n",
                error.kind.name(),
                error.line,
                error.span.start,
                opener,
                quote(&error.what),
                quote(&error.what_to_do)
            ));
        }
    }
}