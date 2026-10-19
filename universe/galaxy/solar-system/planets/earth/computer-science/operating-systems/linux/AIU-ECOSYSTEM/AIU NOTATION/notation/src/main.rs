//! One job: the five commands — parse, render, render-rich, roundtrip, todos — one file path each.
//! Registered in plan/package-tree.org (src/main.rs), provisional 2026-07-17
//! alongside the binary target in Cargo.toml.
//!
//! This binary exists for the one by-hand run allowed in item 3 of TODO.org.
//! Nothing here is automatic, nothing writes outside /tmp unless it is told to,
//! and every failure is named rather than turned into a quiet zero.

use std::time::Instant;

use notation::buffer::Buffer;
use notation::parser::{parse, Node};
use notation::plain::render_plain;
use notation::rich::render_rich;
use notation::rust_exports::parse_document;

/// The columns the rich render draws into when the caller names none. The
/// binary cannot ask the terminal, so it picks a phone's width and says so.
const RICH_DEFAULT_WIDTH: usize = 40;

// usage prints how the binary is called, so a wrong call says what the
// right one is.
/// Say how to call the binary: the five commands and the one file path they take.
fn usage() {
    eprintln!("usage: notation <parse|render|render-rich|roundtrip|todos> <file>");
}
// main reads the command and the file, and hands the work to the one
// command that knows it.

/// Read the file, run the one command named, and exit with the code it earns.
fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        usage();
        std::process::exit(2);
    }
    let command = args[1].clone();
    let path = args[2].clone();

    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("notation: cannot read {}: {}", path, e);
            std::process::exit(2);
        }
    };

    match command.as_str() {
        // Print the payload document on stdout, and the parse time on stderr,
        // so the document can be redirected to a file and still be parseable.
        "parse" => {
            let started = Instant::now();
            let document = parse_document(&path, &text);
            let elapsed = started.elapsed();
            print!("{}", document);
            eprintln!("parse-ms: {}", elapsed.as_millis());
        }
        // Print the plain render: the marks are gone, the content is not.
        "render" => {
            print!("{}", render_plain(&text));
        }
        // Print the rich render: the same content, drawn with unicode.
        "render-rich" => {
            print!("{}", render_rich(&text, RICH_DEFAULT_WIDTH));
        }
        // Say whether the tree prints back to the identical bytes.
        "roundtrip" => {
            let buffer = Buffer::from_text(&text);
            let tree = parse(&buffer);
            let printed = tree.print_back(&buffer);
            if tree.round_trips(&buffer) {
                println!("roundtrip: identical ({} bytes)", printed.len());
            } else {
                println!("roundtrip: not identical ({} bytes out)", printed.len());
                std::process::exit(1);
            }
        }
        // List every todo in the page. A todo may sit on any block and inside
        // any comment, so the whole page is read line by line.
        "todos" => {
            let buffer = Buffer::from_text(&text);
            let tree = parse(&buffer);
            let mut opaque: Vec<(usize, usize)> = Vec::new();
            collect_opaque_bodies(&tree.nodes, &buffer, &mut opaque);
            for line in todo_lines(&text, &opaque) {
                println!("{}", line);
            }
        }
        other => {
            eprintln!("notation: no command named {}", other);
            usage();
            std::process::exit(2);
        }
    }
}

// collect_opaque_bodies gathers the line ranges of the bodies of the opaque
// blocks in the tree. A code body is not read as notation, so a todo written
// there is not a todo of the page.
fn collect_opaque_bodies(nodes: &[Node], buffer: &Buffer, out: &mut Vec<(usize, usize)>) {
    for node in nodes {
        if let Node::Block(block) = node {
            if block.is_opaque() {
                let end_line = buffer.line_at(block.span.end);
                if end_line > block.line + 1 {
                    out.push((block.line + 1, end_line - 1));
                }
            }
            collect_opaque_bodies(&block.children, buffer, out);
        }
    }
}

// todo_lines reads the page line by line and answers every todo it holds. The
// page is read as a whole and not through the tree, because the tree knows a
// declaration only when the line is straight under the start line, and a todo
// must be found wherever it is written.
fn todo_lines(text: &str, opaque: &[(usize, usize)]) -> Vec<String> {
    let mut found = Vec::new();
    for (index, line) in text.split('\n').enumerate() {
        let number = index + 1;
        let hidden = opaque.iter().any(|(first, last)| number >= *first && number <= *last);
        if hidden {
            continue;
        }
        let trimmed = line.trim_start();
        if let Some(words) = trimmed.strip_prefix("todo:") {
            found.push(format!("todo line {}: {}", number, words.trim()));
        }
    }
    found
}
