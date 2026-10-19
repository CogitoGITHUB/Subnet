//! One job: the four commands — parse, render, render-rich, roundtrip — one file path each.
//! Registered in plan/package-tree.org (src/main.rs), provisional 2026-07-17
//! alongside the binary target in Cargo.toml.
//!
//! This binary exists for the one by-hand run allowed in item 3 of TODO.org.
//! Nothing here is automatic, nothing writes outside /tmp unless it is told to,
//! and every failure is named rather than turned into a quiet zero.

use std::time::Instant;

use notation::buffer::Buffer;
use notation::parser::parse;
use notation::plain::render_plain;
use notation::rich::render_rich;
use notation::rust_exports::parse_document;

/// The columns the rich render draws into when the caller names none. The
/// binary cannot ask the terminal, so it picks a phone's width and says so.
const RICH_DEFAULT_WIDTH: usize = 40;

// usage prints how the binary is called, so a wrong call says what the
// right one is.
/// Say how to call the binary: the four commands and the one file path they take.
fn usage() {
    eprintln!("usage: notation <parse|render|render-rich|roundtrip> <file>");
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
        other => {
            eprintln!("notation: no command named {}", other);
            usage();
            std::process::exit(2);
        }
    }
}