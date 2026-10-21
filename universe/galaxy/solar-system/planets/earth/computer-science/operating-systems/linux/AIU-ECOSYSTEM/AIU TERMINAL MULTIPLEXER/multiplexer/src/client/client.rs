// One job: the client — a thin screen that attaches to a holder, asks it
// things, and lets go again.
//
// The client holds nothing: the shell and the log belong to the holder, so a
// client that ends takes nothing with it (rule 01). It reads no environment
// variable for the session: the state directory is an argument.
//
// Its wait for the holder's socket ends on the filesystem event that creates
// it, never on a clock.

use serde_json::{json, Value};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

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
    wait_for_socket(&socket_path)?;

    let fd = connect(&socket_path)?;
    let request = options.request();
    let mut line = request.to_string();
    line.push('\n');
    write_to(fd, line.as_bytes())?;

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
            let got = read_from(fd, &mut buffer)?;
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
            let got = read_from(libc::STDIN_FILENO, &mut buffer)?;
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
        let _ = write_to(fd, detach.as_bytes());
        let mut answer = String::new();
        let mut buffer = [0u8; 4096];
        let got = read_from(fd, &mut buffer)?;
        if got > 0 {
            answer = String::from_utf8_lossy(&buffer[..got]).trim().to_string();
        }
        if !answer.is_empty() {
            println!("{}", answer);
        }
    }

    close(fd);
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

/// wait_for_socket waits for the holder's socket to appear, and the wait ends
/// on the filesystem event that creates it.
fn wait_for_socket(path: &Path) -> Result<(), String> {
    if path.exists() {
        return Ok(());
    }
    let dir = match path.parent() {
        Some(found) => found.to_path_buf(),
        None => return Err("the socket path has no directory".to_string()),
    };
    if !dir.exists() {
        return Err(format!(
            "the state directory {} does not exist, so no holder can be in it",
            dir.display()
        ));
    }
    let watcher = unsafe { libc::inotify_init() };
    if watcher < 0 {
        return Err("this phone cannot watch for the socket".to_string());
    }
    let watched = match std::ffi::CString::new(dir.as_os_str().as_bytes()) {
        Ok(value) => value,
        Err(_) => {
            close(watcher);
            return Err("the state directory path holds a nul byte".to_string());
        }
    };
    let watch = unsafe {
        libc::inotify_add_watch(
            watcher,
            watched.as_ptr(),
            libc::IN_CREATE | libc::IN_MOVED_TO,
        )
    };
    if watch < 0 {
        close(watcher);
        return Err(format!(
            "the state directory {} cannot be watched",
            dir.display()
        ));
    }
    let mut buffer = [0u8; 4096];
    while !path.exists() {
        let got = unsafe { libc::read(watcher, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
        if got <= 0 {
            break;
        }
        if holder_is_gone(&dir) {
            close(watcher);
            return Err(format!(
                "the holder that was to hold the session in {} is gone",
                dir.display()
            ));
        }
    }
    close(watcher);
    if path.exists() {
        Ok(())
    } else {
        Err(format!(
            "the holder's socket {} never came",
            path.display()
        ))
    }
}

/// holder_is_gone answers whether the holder that wrote its pid into this
/// state directory is no longer there. The client waits on the filesystem,
/// so it asks the kernel about the holder rather than waiting on a clock.
fn holder_is_gone(dir: &Path) -> bool {
    let pid_file = dir.join("holder.pid");
    if !pid_file.exists() {
        return false;
    }
    let said = match std::fs::read_to_string(&pid_file) {
        Ok(body) => body.trim().to_string(),
        Err(_) => return false,
    };
    let pid: libc::pid_t = match said.parse() {
        Ok(value) => value,
        Err(_) => return false,
    };
    if pid <= 0 {
        return false;
    }
    unsafe { libc::kill(pid, 0) != 0 }
}

/// connect opens the connection to the holder's socket.
fn connect(path: &Path) -> Result<libc::c_int, String> {
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err("this phone cannot make a unix socket".to_string());
    }
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    let bytes = path.as_os_str().as_bytes();
    if bytes.len() >= address.sun_path.len() {
        close(fd);
        return Err(format!("the socket path {} is too long", path.display()));
    }
    for (at, byte) in bytes.iter().enumerate() {
        address.sun_path[at] = *byte as libc::c_char;
    }
    let length =
        (std::mem::size_of::<libc::sa_family_t>() + bytes.len() + 1) as libc::socklen_t;
    let put = unsafe {
        libc::connect(
            fd,
            &address as *const libc::sockaddr_un as *const libc::sockaddr,
            length,
        )
    };
    if put != 0 {
        close(fd);
        return Err(format!("the holder's socket {} refused", path.display()));
    }
    Ok(fd)
}

/// read_from waits for bytes and answers how many came.
fn read_from(fd: libc::c_int, buffer: &mut [u8]) -> Result<usize, String> {
    let got = unsafe { libc::read(fd, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
    if got >= 0 {
        Ok(got as usize)
    } else {
        Err(format!("read from fd {} failed", fd))
    }
}

/// write_to puts bytes on a descriptor and answers when they are all in.
fn write_to(fd: libc::c_int, bytes: &[u8]) -> Result<(), String> {
    let mut at = 0;
    while at < bytes.len() {
        let put = unsafe {
            libc::write(
                fd,
                bytes[at..].as_ptr() as *const libc::c_void,
                bytes.len() - at,
            )
        };
        if put <= 0 {
            return Err(format!("write to fd {} failed", fd));
        }
        at += put as usize;
    }
    Ok(())
}

/// close closes one descriptor and says nothing.
fn close(fd: libc::c_int) {
    if fd >= 0 {
        unsafe {
            libc::close(fd);
        }
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
