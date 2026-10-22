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
#[allow(dead_code)]
#[path = "../tty/tty.rs"] mod tty;

// The work mode's config: the devloop area sits below the client, so this is a
// downward edge and the only one the client takes.
#[path = "../devloop/config.rs"]
mod config;

mod git;
mod workspace;
mod editor;
mod keymap;
mod screen;
mod select;

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

    if options.op == "screen" {
        // The screen is its own life: it attaches, draws the panes, and
        // answers the keys until the owner leaves. It carries the config: the
        // file the environment names, else the last good bake in this state
        // directory, else the built-in defaults, and the line says which one
        // answered — the way the editor's start says it.
        let in_force = config::ConfigFile::start(&options.state_dir);
        eprintln!(
            "client: work mode, the config from {}",
            in_force.origin()
        );
        let answer = screen::session(
            fd,
            CLIENT_NAME,
            options.agent_program.clone(),
            options.editor_program.clone(),
            options.editor_mcp.clone(),
            in_force,
        );
        wire::close(fd);
        answer?;
        return Ok(0);
    }

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
            let mut done = false;
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
                            done = true;
                            break;
                        }
                    }
                } else if is_final(&answer) {
                    // the answer says it is the last one of this request
                    done = true;
                    break;
                }
            }
            if done {
                break;
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

        // A pipe that is at its end says POLLHUP, not POLLIN: the end of the
        // keys is an event too, and the client must hear it.
        if watching_stdin && fds[1].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
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

/// is_final answers whether a record is the last one of its request: the
/// holder marks the answer, so the reader knows it is complete without
/// waiting for the connection to close.
fn is_final(line: &str) -> bool {
    match serde_json::from_str::<Value>(line) {
        Ok(value) => value
            .get("result")
            .and_then(|result| result.get("final"))
            .and_then(|flag| flag.as_bool())
            .unwrap_or(false),
        Err(_) => false,
    }
}

/// Options are the client's arguments.
struct Options {
    state_dir: PathBuf,
    op: String,
    data: String,
    pane: String,
    agent_program: String,
    editor_program: String,
    editor_mcp: Vec<String>,
    since: u64,
    count: Option<u64>,
}

impl Options {
    fn read(args: &[String]) -> Result<Options, String> {
        let mut state_dir: Option<PathBuf> = None;
        let mut op = "state".to_string();
        let mut data = String::new();
        let mut pane = String::new();
        let mut agent_program = "opencode".to_string();
        let mut editor_program = "editor".to_string();
        let mut editor_mcp: Vec<String> = Vec::new();
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
                "--pane" => {
                    pane = value;
                    at += 2;
                }
                "--agent-program" => {
                    agent_program = value;
                    at += 2;
                }
                "--editor-program" => {
                    editor_program = value;
                    at += 2;
                }
                "--editor-mcp-arg" => {
                    // The command that starts the editor's own server: the
                    // program first, and then what it runs. It is given one
                    // word at a time, so a path with a space in it is still
                    // one path.
                    editor_mcp.push(value);
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
                        "client --state-dir DIR [--op state|attach|detach|read|send|send-agent|editor|screen] [--data TEXT] [--pane NAME] [--agent-program PROGRAM] [--editor-mcp-arg WORD] [--since N] [--count N]"
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
            pane,
            agent_program,
            editor_program,
            editor_mcp,
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
            "send" => {
                let mut request = json!({ "op": "send", "client": CLIENT_NAME, "data": self.data });
                if !self.pane.is_empty() {
                    request["pane"] = Value::from(self.pane.clone());
                }
                request
            }
            "send-agent" => {
                let mut request = json!({
                    "op": "send-agent",
                    "client": CLIENT_NAME,
                    "selection": self.data,
                    "target": screen::agent_name(&self.agent_program),
                    "why": "the owner sent the picked text to the agents",
                });
                if !self.pane.is_empty() {
                    request["from"] = Value::from(self.pane.clone());
                }
                request
            }
            "editor" => json!({
                "op": "editor",
                "client": CLIENT_NAME,
                "command": self.editor_mcp,
                "capability": "dashboard"
            }),
            _ => json!({ "op": "state", "client": CLIENT_NAME }),
        }
    }
}
