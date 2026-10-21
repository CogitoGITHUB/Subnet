// One job: the one-shot program — one request in a file, one answer in a
// file.
//
// The editor's join seam carries the two languages over files, because a
// child given a pipe is mute in that Racket build. This program speaks the
// same way: it reads a request file and writes an answer file, and it never
// waits on a stream.

use std::path::PathBuf;

use workspace::Engine;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => {}
        Err(why) => {
            eprintln!("{}", why);
            std::process::exit(2);
        }
    }
}

/// run reads the request, asks the engine, and writes the answer.
fn run(args: &[String]) -> Result<(), String> {
    let mut state_dir: Option<PathBuf> = None;
    let mut request: Option<PathBuf> = None;
    let mut response: Option<PathBuf> = None;
    let mut at = 0;
    while at < args.len() {
        match args[at].as_str() {
            "--state-dir" => {
                at += 1;
                state_dir = Some(PathBuf::from(
                    args.get(at)
                        .ok_or("--state-dir needs a directory")?,
                ));
            }
            "--request" => {
                at += 1;
                request = Some(PathBuf::from(
                    args.get(at).ok_or("--request needs a file")?,
                ));
            }
            "--response" => {
                at += 1;
                response = Some(PathBuf::from(
                    args.get(at).ok_or("--response needs a file")?,
                ));
            }
            "--help" => {
                println!(
                    "workspace --state-dir DIR --request FILE --response FILE\n\n\
                     One request in, one answer out. The answer is the one\n\
                     envelope: protocol, request, op, state, data, reason."
                );
                return Ok(());
            }
            other => return Err(format!("{} is not an option this program knows", other)),
        }
        at += 1;
    }
    let state_dir = state_dir.ok_or("the program needs --state-dir")?;
    let request = request.ok_or("the program needs --request")?;
    let response = response.ok_or("the program needs --response")?;
    let text = std::fs::read_to_string(&request)
        .map_err(|why| format!("the request file {} cannot be read: {}", request.display(), why))?;
    let value: serde_json::Value = serde_json::from_str(&text).map_err(|why| {
        format!(
            "the request file {} does not hold a request: {}",
            request.display(),
            why
        )
    })?;
    let engine = Engine::open(&state_dir)?;
    let answer = engine.apply(&value);
    std::fs::write(&response, answer.to_string()).map_err(|why| {
        format!(
            "the answer file {} cannot be written: {}",
            response.display(),
            why
        )
    })
}
