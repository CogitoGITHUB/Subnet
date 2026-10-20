// One job: the Rust side of the seam — one request file in, one answer file
// out. It holds no session of its own: the meaning side starts it, sends
// one request, reads one answer, and it goes. The state lives in the file
// and in the journal; the buffer is rebuilt from them every time, so a
// crash costs nothing (rule 01).

#[path = "../buffer/buffer.rs"]
mod buffer;
#[path = "../dashboard/dashboard.rs"]
mod dashboard;
#[path = "../journal/journal.rs"]
mod journal;
#[path = "wire-json.rs"]
mod wire_json;
#[path = "rust-exports.rs"]
mod rust_exports;

use std::env;
use std::fs;

/// main reads the request, does the work, and writes the answer. The
/// request file and the answer file are the two arguments: the wire is a
/// pair of files, because this build hands a child nothing for a pipe.
fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("the hot path needs the request file and the answer file");
        std::process::exit(2);
    }
    let request_path = args[1].clone();
    let answer_path = args[2].clone();

    let request_text = match fs::read_to_string(&request_path) {
        Ok(text) => text,
        Err(why) => {
            eprintln!("the request file cannot be read: {}", why);
            std::process::exit(2);
        }
    };
    let line = request_text.lines().next().unwrap_or("");
    let request = match wire_json::read_request(line) {
        Some(request) => request,
        None => {
            write_answer(
                &answer_path,
                false,
                &[
                    ("kind".to_string(), "err-bad-request".to_string()),
                    ("what".to_string(), "the request line is not a request".to_string()),
                    ("what_to_do".to_string(), "ask for one op with string args".to_string()),
                ],
            );
            return;
        }
    };

    let (ok, data) = answer_for(&request);
    write_answer(&answer_path, ok, &data);
}

/// answer_for does the work the request asks for, and answers whether it
/// worked and what it learned.
fn answer_for(request: &wire_json::Request) -> (bool, Vec<(String, String)>) {
    let file = wire_json::arg(request, "file");
    let journal_path = wire_json::arg(request, "journal");
    let op = request.op.as_str();

    match op {
        rust_exports::OP_OPEN => {
            let text = current_text(&file, &journal_path);
            let state = buffer::new_buffer(&text);
            let pending = journal::records(&journal_path).len();
            (
                true,
                vec![
                    ("file".to_string(), file),
                    ("lines".to_string(), buffer::line_count(&state).to_string()),
                    ("bytes".to_string(), buffer::byte_len(&state).to_string()),
                    ("pending".to_string(), pending.to_string()),
                ],
            )
        }
        rust_exports::OP_INSERT => {
            let more = wire_json::arg(request, "text");
            let text = current_text(&file, &journal_path);
            let mut state = buffer::new_buffer(&text);
            let bytes = buffer::append(&mut state, &more);
            let record = format!("insert {}", journal::escape(&more));
            let pending = journal::append_record(&journal_path, &record);
            (
                true,
                vec![
                    ("bytes".to_string(), bytes.to_string()),
                    ("lines".to_string(), buffer::line_count(&state).to_string()),
                    ("pending".to_string(), pending.to_string()),
                ],
            )
        }
        rust_exports::OP_SAVE => {
            let text = current_text(&file, &journal_path);
            if let Err(why) = fs::write(&file, &text) {
                return (
                    false,
                    vec![
                        ("kind".to_string(), "err-no-save".to_string()),
                        ("what".to_string(), format!("the file cannot be written: {}", why)),
                        ("what_to_do".to_string(), "check the path and its permissions".to_string()),
                    ],
                );
            }
            journal::clear(&journal_path);
            let state = buffer::new_buffer(&text);
            (
                true,
                vec![
                    ("file".to_string(), file),
                    ("bytes".to_string(), buffer::byte_len(&state).to_string()),
                    ("lines".to_string(), buffer::line_count(&state).to_string()),
                    ("pending".to_string(), "0".to_string()),
                ],
            )
        }
        rust_exports::OP_SHOW => {
            let text = current_text(&file, &journal_path);
            let state = buffer::new_buffer(&text);
            (
                true,
                vec![
                    ("text".to_string(), buffer::text_of(&state).to_string()),
                    ("lines".to_string(), buffer::line_count(&state).to_string()),
                    ("bytes".to_string(), buffer::byte_len(&state).to_string()),
                ],
            )
        }
        rust_exports::OP_JOURNAL => {
            let records = journal::records(&journal_path);
            (
                true,
                vec![
                    ("count".to_string(), records.len().to_string()),
                    ("records".to_string(), records.join("\n")),
                ],
            )
        }
        rust_exports::OP_REPLAY => {
            let text = current_text(&file, &journal_path);
            let state = buffer::new_buffer(&text);
            let records = journal::records(&journal_path);
            (
                true,
                vec![
                    ("text".to_string(), buffer::text_of(&state).to_string()),
                    ("lines".to_string(), buffer::line_count(&state).to_string()),
                    ("bytes".to_string(), buffer::byte_len(&state).to_string()),
                    ("pending".to_string(), records.len().to_string()),
                    ("records".to_string(), records.join("\n")),
                ],
            )
        }
        rust_exports::OP_DASHBOARD => {
            let width = wire_json::arg(request, "width")
                .trim()
                .parse::<usize>()
                .unwrap_or(80);
            let height = wire_json::arg(request, "height")
                .trim()
                .parse::<usize>()
                .unwrap_or(24);
            let count = wire_json::arg(request, "count")
                .trim()
                .parse::<usize>()
                .unwrap_or(0);
            let pieces = dashboard::parse_pieces(&request.args, count);
            let screen = dashboard::draw(&pieces, width, height);
            (
                true,
                vec![("screen".to_string(), screen.join("\n"))],
            )
        }
        _ => (
            false,
            vec![
                ("kind".to_string(), "err-unknown-op".to_string()),
                ("what".to_string(), format!("there is no operation named {}", op)),
                ("what_to_do".to_string(), "ask for one of: open, insert, save, show, journal, replay, dashboard".to_string()),
            ],
        ),
    }
}

/// current_text answers the text as it stands: the saved file, with the
/// journal's unsaved edits put back on top. A file that is not there yet
/// reads as empty.
fn current_text(file: &str, journal_path: &str) -> String {
    let saved = match fs::read_to_string(file) {
        Ok(text) => text,
        Err(_) => String::new(),
    };
    let records = journal::records(journal_path);
    journal::replay(&saved, &records)
}

/// write_answer writes the answer as one line of JSON, and says on stderr
/// when the answer file cannot be written.
fn write_answer(answer_path: &str, ok: bool, data: &[(String, String)]) {
    let text = wire_json::write_response(ok, data);
    if let Err(why) = fs::write(answer_path, format!("{}\n", text)) {
        eprintln!("the answer file cannot be written: {}", why);
        std::process::exit(2);
    }
}
