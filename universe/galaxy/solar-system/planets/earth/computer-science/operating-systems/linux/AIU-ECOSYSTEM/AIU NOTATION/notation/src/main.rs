//! One job: the three commands — parse, render, roundtrip — one file path each.
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
use notation::rust_exports::parse_document;

fn usage() {
    eprintln!("usage: notation <parse|render|roundtrip> <file>");
}

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