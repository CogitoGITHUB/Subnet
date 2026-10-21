// One job: the client — a thin screen that attaches to a holder, asks it
// things, and lets go again.
//
// The client holds nothing: the shell and the log belong to the holder, so a
// client that ends takes nothing with it (rule 01). It reads no environment
// variable for the session: the state directory is an argument.
//
// Its wait for the holder's socket ends on the filesystem event that creates
// it, never on a clock.

#[path = "../holder/wire.rs"] mod wire;

use serde_json::{json, Value};
use std::path::PathBuf;

const EVENT_CONTRACT: &str = "event-log-format/1";
const HOLDER_CONTRACT: &str = "multiplexer-holder/1";
const CLIENT_NAME: &str = "multiplexer-client/1";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(code) => std::process::exit(code),
        Err(why) => {
            eprintln!("client: {}", why);
            std::process::exit(1);
        }
    }
}

/// run asks the holder one thing and prints what it answers.
fn run(args: &[String]) -> Result<i32, String> {
    let options = Options::read(args)?;
    let socket_path = options.state_dir.join("holder.sock");

    eprintln!(
        "client: waiting for the holder's socket at {}",
        socket_path.display()
    );
    wire::wait_for_socket(&socket_path)?;

    let fd = wire::connect(&socket_path)?;
    wire::ask(fd, &options.request())?;

    let mut refused = false;
    let mut printed = 0u64;
    let mut pending = String::new();
    loop {
        // Only an attached client watches the keyboard: stdin is how a person
        // says "detach". A one-shot request never reads it, so a closed
        // stdin cannot end the request before the answer arrives.
        let watching_stdin = options.op == "attach" && options.count.is_none();
        let mut fds = vec![libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        }];
        if watching_stdin {
            fds.push(libc::pollfd {
                fd: libc::STDIN_FILENO,
                events: libc::POLLIN,
                revents: 0,
            });
        }
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
        if ready < 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err("the client cannot wait for the holder".to_string());
        }

        if fds[0].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            let mut buffer = [0u8; 4096];
            let got = wire::read(fd, &mut buffer)?;
            if got == 0 {
                break;
            }
            pending.push_str(&String::from_utf8_lossy(&buffer[..got]));
            let mut lines = 0u64;
            while let Some(at) = pending.find('\n') {
                let answer = pending[..at].trim().to_string();
                pending = pending[at + 1..].to_string();
                if answer.is_empty() {
                    continue;
                }
                if is_refusal(&answer) {
                    refused = true;
                }
                println!("{}", answer);
                printed += 1;
                lines += 1;
                if options.op == "attach" {
                    if let Some(wanted) = options.count {
                        if printed >= wanted {
                            break;
                        }
                    }
                } else if options.op != "read" {
                    // one answer is the whole answer for state and for send
                    break;
                }
            }
            if options.op == "attach" {
                if let Some(wanted) = options.count {
                    if printed >= wanted {
                        break;
                    }
                }
            } else if options.op != "read" && lines > 0 {
                break;
            }
            continue;
        }

        if watching_stdin && fds[1].revents & libc::POLLIN != 0 {
            let mut buffer = [0u8; 1024];
            let got = wire::read(libc::STDIN_FILENO, &mut buffer)?;
            if got == 0 {
                break;
            }
            let said = String::from_utf8_lossy(&buffer[..got]).trim().to_string();
            if said == "detach" {
                break;
            }
        }
    }

    if options.op == "attach" {
        let mut detach = json!({ "op": "detach", "client": CLIENT_NAME }).to_string();
        detach.push('\n');
        let _ = wire::write(fd, detach.as_bytes());
        let mut answer = String::new();
        let mut buffer = [0u8; 4096];
        let got = wire::read(fd, &mut buffer)?;
        if got > 0 {
            answer = String::from_utf8_lossy(&buffer[..got]).trim().to_string();
        }
        if !answer.is_empty() {
            println!("{}", answer);
        }
    }

    wire::close(fd);
    Ok(if refused { 1 } else { 0 })
}

/// is_refusal answers whether a record is the holder refusing, so the client
/// can say so with its exit code.
fn is_refusal(line: &str) -> bool {
    match serde_json::from_str::<Value>(line) {
        Ok(value) => value.get("kind").and_then(|kind| kind.as_str()) == Some("fail"),
        Err(_) => false,
    }
}

/// Options are the client's arguments.
struct Options {
    state_dir: PathBuf,
    op: String,
    data: String,
    since: u64,
    count: Option<u64>,
}

impl Options {
    fn read(args: &[String]) -> Result<Options, String> {
        let mut state_dir: Option<PathBuf> = None;
        let mut op = "state".to_string();
        let mut data = String::new();
        let mut since: u64 = 0;
        let mut count: Option<u64> = None;
        let mut at = 0;
        while at < args.len() {
            let name = args[at].clone();
            let value = match args.get(at + 1) {
                Some(found) => found.clone(),
                None => return Err(format!("{} needs a value", name)),
            };
            match name.as_str() {
                "--state-dir" => {
                    state_dir = Some(PathBuf::from(value));
                    at += 2;
                }
                "--op" => {
                    op = value;
                    at += 2;
                }
                "--data" => {
                    data = value;
                    at += 2;
                }
                "--since" => {
                    since = value
                        .parse()
                        .map_err(|_| "--since wants a number of records".to_string())?;
                    at += 2;
                }
                "--count" => {
                    count = Some(
                        value
                            .parse()
                            .map_err(|_| "--count wants a number of records".to_string())?,
                    );
                    at += 2;
                }
                "--help" => {
                    println!(
                        "client --state-dir DIR [--op state|attach|detach|read|send] [--data TEXT] [--since N] [--count N]"
                    );
                    std::process::exit(0);
                }
                other => return Err(format!("{} is not an option this client knows", other)),
            }
        }
        let state_dir = state_dir.ok_or("the client needs --state-dir")?;
        Ok(Options {
            state_dir,
            op,
            data,
            since,
            count,
        })
    }

    /// request is the one JSON object the client puts on the wire.
    fn request(&self) -> Value {
        match self.op.as_str() {
            "attach" => json!({
                "op": "attach",
                "client": CLIENT_NAME,
                "event-contract": EVENT_CONTRACT,
                "holder-contract": HOLDER_CONTRACT
            }),
            "detach" => json!({ "op": "detach", "client": CLIENT_NAME }),
            "read" => json!({ "op": "read", "client": CLIENT_NAME, "since": self.since }),
            "send" => json!({ "op": "send", "client": CLIENT_NAME, "data": self.data }),
            _ => json!({ "op": "state", "client": CLIENT_NAME }),
        }
    }
}
