// One job: the session — the holder that outlives every client, keeps the
// shell alive, and serves the socket.
//
// No config and no timers (rule 03): the state directory is an argument and
// no environment variable is read for it, no clock is started, and nothing is
// polled in a loop. Every wait ends on an event — the shell wrote, the shell
// exited, a client asked, the socket closed — through one poll that waits for
// exactly those events and nothing else.
//
// The wire is one JSON object per line (rule 07), in the ecosystem's event
// shape: the client says attach, detach, read, state or send; the holder
// answers with records and never dies because a client went.

#[path = "../tty/facade.rs"] mod facade;
#[path = "../tty/measure.rs"] mod measure;
#[path = "../tty/tty.rs"] mod tty;
mod editor;
mod git;
mod layout;
mod log;
mod workspace;

#[path = "../agents/bundle.rs"]
mod bundle;
mod shells;

use libc::c_int;
use serde_json::{json, Value};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::Instant;

const EVENT_CONTRACT: &str = "event-log-format/1";
const HOLDER_CONTRACT: &str = "multiplexer-holder/1";

/// Client is one connection to the socket: its descriptor, the bytes that
/// arrived but do not yet make a whole request, and whether it is attached.
struct Client {
    fd: c_int,
    pending: String,
    attached: bool,
    dead: bool,
    /// role says what this client is: the screen is the owner's own view of
    /// the session, and the agent's words run there. A client with no role
    /// is a reader.
    role: String,
}

/// Pending is one agent's request that waits for the screen's answer: the
/// id of the request and the descriptor of the client that asked.
struct Pending {
    id: String,
    requester_fd: c_int,
}

/// Session is one held session: its panes, its log, its socket and its
/// clients.
struct Session {
    run_id: String,
    state_dir: PathBuf,
    /// workspace_dir is where the shared workspace engine keeps its files.
    workspace_dir: PathBuf,
    /// workspace is the workspace this session works on, when the owner
    /// names one.
    workspace: String,
    log_path: PathBuf,
    socket_path: PathBuf,
    log: log::Log,
    panes: Vec<Pane>,
    tabs: Vec<String>,
    direction: String,
    cols: u16,
    rows: u16,
    seq: u64,
    started: Instant,
    listen_fd: c_int,
    clients: Vec<Client>,
    /// pending are the agent's requests that wait for the screen's answer.
    pending: Vec<Pending>,
}

/// Pane is one pane of the session: a name and the shell it holds. The name
/// is how everything else talks about the pane.
struct Pane {
    name: String,
    tab: String,
    weight: u16,
    /// args are the arguments the program was started with: a restarted pane
    /// runs the same program the same way.
    args: Vec<String>,
    /// typed is what the owner has typed into this pane since the last
    /// newline: the command the pane is given is the line that ends here.
    typed: String,
    shell: shells::Shell,
}

/// AGENT_PANES are the panes a bundle goes to: the multiplexer's own agent
/// and the editor's agent. Both run the same agent program, so one bundle
/// serves both, and a pane with another name is not an agent.
const AGENT_PANES: [&str; 2] = ["agent", "editor-agent"];

/// pane_log_tail answers the last words one pane's program said, as the
/// session's log holds them. It reads the log and never the drawing.
fn pane_log_tail(session: &Session, pane: &str, limit: usize) -> String {
    let held = match log::Log::records(&session.log_path) {
        Ok(held) => held,
        Err(_) => return String::new(),
    };
    let mut lines: Vec<String> = Vec::new();
    for record in held.iter().rev().take(limit).rev() {
        if record.get("who").and_then(|value| value.as_str()) != Some(pane) {
            continue;
        }
        if let Some(text) = record
            .get("outputs")
            .and_then(|outputs| outputs.get("text"))
            .and_then(|value| value.as_str())
        {
            lines.push(text.to_string());
        }
    }
    lines.join("\n")
}

/// command_record answers the command one pane was given and what that pane
/// printed after it: the two parts of one record, read from the log. A pane
/// with no command yet answers nothing, and the bundle carries neither part.
fn command_record(session: &Session, pane: &str) -> (String, String) {
    if pane.is_empty() {
        return (String::new(), String::new());
    }
    let held = match log::Log::records(&session.log_path) {
        Ok(held) => held,
        Err(_) => return (String::new(), String::new()),
    };
    let mut command = String::new();
    let mut at = 0;
    for (number, record) in held.iter().enumerate() {
        let of_pane = record
            .get("inputs")
            .and_then(|inputs| inputs.get("pane"))
            .and_then(|value| value.as_str());
        let is_command = record.get("kind").and_then(|value| value.as_str()) == Some("command");
        if is_command && of_pane == Some(pane) {
            command = record
                .get("inputs")
                .and_then(|inputs| inputs.get("command"))
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            at = number + 1;
        }
    }
    if command.is_empty() {
        return (String::new(), String::new());
    }
    let mut said: Vec<String> = Vec::new();
    for record in held.iter().skip(at) {
        if record.get("who").and_then(|value| value.as_str()) != Some(pane) {
            continue;
        }
        if let Some(text) = record
            .get("outputs")
            .and_then(|outputs| outputs.get("text"))
            .and_then(|value| value.as_str())
        {
            said.push(text.to_string());
        }
    }
    (command, said.join("\n"))
}

/// Fields are the story of one record: what happened, who did it, why, and
/// how. The identity and timing fields are added by the session itself.
struct Fields<'a> {
    kind: &'a str,
    who: &'a str,
    what: &'a str,
    why: &'a str,
    how: &'a str,
    inputs: Value,
    outputs: Value,
    result: Value,
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => {}
        Err(why) => {
            eprintln!("holder: {}", why);
            std::process::exit(1);
        }
    }
}

/// run holds one session from the first moment to the last.
fn run(args: &[String]) -> Result<(), String> {
    let options = Options::read(args)?;
    std::fs::create_dir_all(&options.state_dir).map_err(|why| {
        format!(
            "the state directory {} cannot be made: {}",
            options.state_dir.display(),
            why
        )
    })?;

    let log_path = options.state_dir.join("events.log");
    let socket_path = options.state_dir.join("holder.sock");
    let pid_path = options.state_dir.join("holder.pid");

    if socket_path.exists() {
        match connect(&socket_path) {
            Ok(fd) => {
                close(fd);
                return Err(format!(
                    "a holder already holds the session in {}",
                    options.state_dir.display()
                ));
            }
            Err(_) => {
                std::fs::remove_file(&socket_path).map_err(|why| {
                    format!("the stale socket {} cannot be removed: {}", socket_path.display(), why)
                })?;
            }
        }
    }

    let log = log::Log::open(&log_path)?;
    let listen_fd = bind(&socket_path)?;

    // The panes of the session: the layout file names them, or the smallest
    // layout there is holds one pane with one shell.
    let wanted = match &options.layout {
        Some(path) => layout::read(path)?,
        None => layout::one("main", &options.shell, options.cols, options.rows),
    };
    let direction = wanted.direction.clone();
    let mut panes: Vec<Pane> = Vec::new();
    let mut tabs: Vec<String> = Vec::new();
    for pane in wanted.panes {
        let shell = shells::Shell::start(&pane.program, &[], pane.cols, pane.rows)?;
        if !tabs.contains(&pane.tab) {
            tabs.push(pane.tab.clone());
        }
        panes.push(Pane {
            name: pane.name,
            tab: pane.tab,
            weight: pane.weight,
            args: Vec::new(),
            typed: String::new(),
            shell,
        });
    }

    let run_id = format!("mux-{}-{}", options.shell.replace('/', "-"), std::process::id());
    let mut session = Session {
        run_id,
        state_dir: options.state_dir.clone(),
        workspace_dir: options.workspace_dir.clone(),
        workspace: options.workspace.clone(),
        log_path,
        socket_path,
        log,
        panes,
        tabs,
        direction,
        cols: options.cols,
        rows: options.rows,
        seq: 0,
        started: Instant::now(),
        listen_fd,
        clients: Vec::new(),
        pending: Vec::new(),
    };

    std::fs::write(&pid_path, format!("{}", std::process::id())).map_err(|why| {
        format!(
            "the holder's pid cannot be written to {}: {}",
            pid_path.display(),
            why
        )
    })?;

    let mut measured: serde_json::Map<String, Value> = serde_json::Map::new();
    for (key, value) in measure::record(&session.panes[0].shell.measured) {
        measured.insert(key.to_string(), value);
    }
    let start = session.record(Fields {
        kind: "start",
        who: "holder",
        what: "the session holds its panes",
        why: "the holder was asked to hold a session",
        how: "a pty was opened for every pane, the shell was started on it, the socket was bound",
        inputs: json!({
            "state-dir": options.state_dir.display().to_string(),
            "layout": match &options.layout {
                Some(path) => path.display().to_string(),
                None => "one pane".to_string(),
            },
            "panes": session.panes.iter().map(|pane| pane.name.clone()).collect::<Vec<String>>()
        }),
        outputs: json!({
            "session": session.run_id.clone(),
            "socket": session.socket_path.display().to_string(),
            "log": session.log_path.display().to_string(),
            "measured": Value::Object(measured)
        }),
        result: json!({}),
    });
    session.write(&start);

    serve(&mut session)
}

impl Session {
    /// screen_client answers the descriptor of the screen: the client that
    /// attached as the screen. The agent's words run there, because the
    /// screen is the owner's own view of the session.
    fn screen_client(&self) -> Option<c_int> {
        self.clients
            .iter()
            .find(|client| client.role == "screen" && !client.dead)
            .map(|client| client.fd)
    }

    /// token answers the human's token: the environment first, then the file
    /// in the session's own directory, then the file in the sessions
    /// directory above it. The empty text means there is no token, and a
    /// change is refused.
    fn token(&self) -> String {
        if let Ok(from_env) = std::env::var("AIU_MULTIPLEXER_TOKEN") {
            if !from_env.is_empty() {
                return from_env;
            }
        }
        let mut files = vec![self.state_dir.join("token")];
        if let Some(above) = self.state_dir.parent() {
            files.push(above.join("token"));
        }
        for file in files {
            if let Ok(body) = std::fs::read_to_string(&file) {
                let said = body.trim().to_string();
                if !said.is_empty() {
                    return said;
                }
            }
        }
        String::new()
    }

    /// token_matches answers whether the given token is the session's own.
    /// The holder compares it itself: the caller's word is not taken for
    /// what it does (rule 07).
    fn token_matches(&self, given: &str) -> bool {
        if given.is_empty() {
            return false;
        }
        let own = self.token();
        !own.is_empty() && given == own
    }

    /// record builds one event record: the identity and the timing of the
    /// session, plus the story of what happened. The key set is fixed.
    fn record(&mut self, fields: Fields) -> Value {
        self.seq += 1;
        let mut map = serde_json::Map::new();
        map.insert("run-id".to_string(), json!(self.run_id));
        map.insert("seq".to_string(), json!(self.seq));
        map.insert("parent-id".to_string(), json!(""));
        map.insert("kind".to_string(), json!(fields.kind));
        map.insert("depth".to_string(), json!(0));
        map.insert("who".to_string(), json!(fields.who));
        map.insert("what".to_string(), json!(fields.what));
        map.insert("why".to_string(), json!(fields.why));
        map.insert("how".to_string(), json!(fields.how));
        map.insert("inputs".to_string(), fields.inputs);
        map.insert("outputs".to_string(), fields.outputs);
        map.insert("result".to_string(), fields.result);
        map.insert("utc".to_string(), json!(utc_now()));
        map.insert("mono-ms".to_string(), json!(self.started.elapsed().as_millis()));
        map.insert("duration-ms".to_string(), json!(0));
        Value::Object(map)
    }

    /// write puts one record in the log and on every attached client's wire.
    /// A log that cannot be written ends the session: the log IS the record.
    fn write(&mut self, record: &Value) {
        if let Err(why) = self.log.append(record) {
            eprintln!("holder: {}", why);
            std::process::exit(1);
        }
        self.broadcast(record);
    }

    /// broadcast sends one record to every attached client. A client that
    /// cannot take it is marked dead and dropped at the end of the round: it
    /// is a screen, not the session.
    fn broadcast(&mut self, record: &Value) {
        let mut line = record.to_string();
        line.push('\n');
        for client in self.clients.iter_mut() {
            if !client.attached {
                continue;
            }
            if let Err(why) = write_to(client.fd, line.as_bytes()) {
                eprintln!("holder: the client on fd {} is dropped: {}", client.fd, why);
                client.dead = true;
            }
        }
    }

    /// state answers what the session holds: its panes, the log, the socket,
    /// the clients, and the contracts a client must agree with.
    fn state(&mut self, why: &str) -> Value {
        let attached = self.clients.iter().filter(|c| c.attached).count();
        let workspace_dir = self.workspace_dir.clone();
        let workspace_name = self.workspace.clone();
        let workspace = workspace::read(&workspace_dir, &workspace_name, "list");
        let mut panes: Vec<Value> = Vec::new();
        for pane in &self.panes {
            panes.push(json!({
                "name": pane.name.clone(),
                "tab": pane.tab.clone(),
                "pid": pane.shell.pid,
                "alive": pane.shell.alive_now(),
                "program": pane.shell.program.clone(),
                "weight": pane.weight,
                // The pane's recent words: the log holds them, and the
                // client that attaches sees the pane as it is.
                "text": pane_log_tail(self, &pane.name, 50)
            }));
        }
        self.record(Fields {
            kind: "info",
            who: "holder",
            what: "what this session holds",
            why: why,
            how: "the holder read its own memory and asked the kernel about every pane",
            inputs: json!({}),
            outputs: json!({
                "session": self.run_id.clone(),
                "direction": self.direction.clone(),
                "tabs": Value::Array(
                    self.tabs
                        .iter()
                        .map(|tab| Value::from(tab.clone()))
                        .collect::<Vec<Value>>(),
                ),
                "panes": Value::Array(panes),
                "log": self.log_path.display().to_string(),
                "socket": self.socket_path.display().to_string(),
                "state-dir": self.state_dir.display().to_string(),
                "records": self.seq,
                "clients": self.clients.len(),
                "attached": attached,
                "event-contract": EVENT_CONTRACT,
                "holder-contract": HOLDER_CONTRACT,
                "workspace": workspace.data
            }),
            result: json!({}),
        })
    }
}

/// pane_at answers the pane of that name, or the first pane when the name is
/// empty: the session's panes are addressed by name.
fn pane_at(session: &Session, name: &str) -> Result<usize, String> {
    if name.is_empty() {
        return Ok(0);
    }
    session
        .panes
        .iter()
        .position(|pane| pane.name == name)
        .ok_or_else(|| format!("there is no pane named {}", name))
}

/// serve waits for events and answers them, until every pane has ended.
fn serve(session: &mut Session) -> Result<(), String> {
    loop {
        let mut fds: Vec<libc::pollfd> = Vec::with_capacity(2 + session.panes.len() + session.clients.len());
        for pane in &session.panes {
            fds.push(libc::pollfd {
                fd: pane.shell.master,
                events: libc::POLLIN,
                revents: 0,
            });
        }
        let pane_count = session.panes.len();
        fds.push(libc::pollfd {
            fd: session.listen_fd,
            events: libc::POLLIN,
            revents: 0,
        });
        for client in &session.clients {
            fds.push(libc::pollfd {
                fd: client.fd,
                events: libc::POLLIN,
                revents: 0,
            });
        }
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
        if ready < 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err("the holder cannot wait for events".to_string());
        }

        let mut ended: Vec<usize> = Vec::new();
        for pane_at in 0..pane_count {
            if fds[pane_at].revents & (libc::POLLIN | libc::POLLHUP) == 0 {
                continue;
            }
            if !read_shell(session, pane_at)? {
                ended.push(pane_at);
            }
        }
        // A pane whose program ended goes on its own: the session and the
        // other panes go on. The session ends when the last pane is gone.
        for pane_at in ended.into_iter().rev() {
            close_pane(session, pane_at);
        }
        if session.panes.is_empty() {
            break;
        }

        if fds[pane_count].revents & libc::POLLIN != 0 {
            let fd = unsafe {
                libc::accept(
                    session.listen_fd,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            };
            if fd >= 0 {
                session.clients.push(Client {
                    fd,
                    pending: String::new(),
                    attached: false,
                    dead: false,
                    role: String::new(),
                });
            }
        }

        let mut finished: Vec<usize> = Vec::new();
        for at in (pane_count + 1)..fds.len() {
            if fds[at].revents & (libc::POLLIN | libc::POLLHUP) == 0 {
                continue;
            }
            let client_at = at - (pane_count + 1);
            if !read_client(session, client_at)? {
                finished.push(client_at);
            }
        }
        for at in finished.into_iter().rev() {
            let client = session.clients.remove(at);
            close(client.fd);
        }
        let mut gone: Vec<usize> = Vec::new();
        for (at, client) in session.clients.iter().enumerate() {
            if client.dead {
                gone.push(at);
            }
        }
        for at in gone.into_iter().rev() {
            let client = session.clients.remove(at);
            close(client.fd);
        }
    }

    let mut statuses: Vec<String> = Vec::new();
    for pane in &session.panes {
        statuses.push(pane.shell.wait());
    }
    let end = session.record(Fields {
        kind: "end",
        who: "holder",
        what: "the panes ended, the session is over",
        why: "the shells closed their terminals",
        how: "the masters read no bytes and every shell was waited for",
        inputs: json!({}),
        outputs: json!({}),
        result: json!({ "status": statuses.join(", ") }),
    });
    session.write(&end);
    close(session.listen_fd);
    let _ = std::fs::remove_file(&session.socket_path);
    Ok(())
}

/// read_shell takes what one pane's shell wrote and records it, under that
/// pane's name. It answers whether the session continues.
fn read_shell(session: &mut Session, pane_at: usize) -> Result<bool, String> {
    let mut buffer = [0u8; 4096];
    // A terminal that breaks is one pane's program gone: the session and
    // the other panes go on.
    let got = match session.panes[pane_at].shell.read(&mut buffer) {
        Ok(got) => got,
        Err(why) => {
            let pane_name = session.panes[pane_at].name.clone();
            let record = session.record(Fields {
                kind: "info",
                who: &pane_name,
                what: "the pane ended",
                why: "its program is gone and its terminal is closed",
                how: "the read of the terminal failed and the pane was let go",
                inputs: json!({ "pane": pane_name }),
                outputs: json!({}),
                result: json!({ "why": why }),
            });
            session.write(&record);
            return Ok(false);
        }
    };
    if got == 0 {
        return Ok(false);
    }
    let text = tty::plain(&buffer[..got]);
    let pane_name = session.panes[pane_at].name.clone();
    let record = session.record(Fields {
        kind: "progress",
        who: &pane_name,
        what: "the shell wrote",
        why: "the shell had something to say",
        how: "the master read the bytes and the escapes were left out",
        inputs: json!({ "bytes": got, "pane": pane_name }),
        outputs: json!({ "text": text }),
        result: json!({}),
    });
    session.write(&record);
    Ok(true)
}

/// close_pane lets one pane go: its terminal is closed, the log says so,
/// and the panes that are left go on.
fn close_pane(session: &mut Session, pane_at: usize) {
    let pane = session.panes.remove(pane_at);
    close(pane.shell.master);
    let record = session.record(Fields {
        kind: "info",
        who: &pane.name,
        what: "the pane ended",
        why: "its program is gone",
        how: "the terminal was closed and the pane was let go",
        inputs: json!({ "pane": pane.name.clone() }),
        outputs: json!({ "panes": session.panes.len() }),
        result: json!({}),
    });
    session.write(&record);
}

/// read_client takes what a client sent and answers it. It answers whether
/// the client stays connected.
///
/// A client whose socket breaks is one client gone, not the session gone: the
/// read error is answered as "that client is finished", and the panes go on
/// without it.
fn read_client(session: &mut Session, at: usize) -> Result<bool, String> {
    let mut buffer = [0u8; 4096];
    let got = match read_from(session.clients[at].fd, &mut buffer) {
        Ok(got) => got,
        Err(why) => {
            let record = session.record(Fields {
                kind: "info",
                who: "holder",
                what: "the client is gone",
                why: "its socket broke while the holder was reading it",
                how: "the read failed and the client was let go",
                inputs: json!({ "fd": session.clients[at].fd }),
                outputs: json!({}),
                result: json!({ "why": why }),
            });
            session.write(&record);
            return Ok(false);
        }
    };
    if got == 0 {
        return Ok(false);
    }
    let text = String::from_utf8_lossy(&buffer[..got]).to_string();
    session.clients[at].pending.push_str(&text);

    let mut keep = true;
    while let Some(at_newline) = session.clients[at].pending.find('\n') {
        let line: String = session.clients[at].pending[..at_newline].to_string();
        session.clients[at].pending = session.clients[at].pending[at_newline + 1..].to_string();
        if !answer(session, at, line.trim())? {
            keep = false;
        }
    }
    Ok(keep)
}

/// answer handles one request line and answers it on the same wire.
fn answer(session: &mut Session, at: usize, line: &str) -> Result<bool, String> {
    let request: Value = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(why) => {
            let record = session.record(Fields {
                kind: "fail",
                who: "holder",
                what: "the request is not a record",
                why: "the line on the wire is not one JSON object",
                how: "the line was parsed and refused",
                inputs: json!({ "line": line }),
                outputs: json!({}),
                result: json!({ "why": why.to_string() }),
            });
            answer_client(session, at, &record);
            return Ok(false);
        }
    };
    let op = request
        .get("op")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string();

    match op.as_str() {
        "attach" => attach(session, at, &request),
        "detach" => {
            session.clients[at].attached = false;
            let record = session.record(Fields {
                kind: "info",
                who: "client",
                what: "the client detached",
                why: "the client asked to detach",
                how: "the client was answered and the connection was closed",
                inputs: json!({ "client": client_name(&request) }),
                outputs: json!({}),
                result: json!({}),
            });
            session.write(&record);
            answer_client(session, at, &record);
            Ok(false)
        }
        "state" => {
            let record = session.state("the client asked for the state");
            session.write(&record);
            answer_client(session, at, &record);
            // The client stays: a screen asks for the state and then keeps
            // asking things of the same connection.
            Ok(true)
        }
        "git" => {
            // The client asks what Git says here, and the shared layer
            // answers. The layer only reads: it cannot change a
            // repository, an index, a branch or a worktree.
            let what = request
                .get("what")
                .and_then(|value| value.as_str())
                .unwrap_or("overview")
                .to_string();
            let directory = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
            let answer = git::read(&directory, &what);
            let record = session.record(Fields {
                kind: if answer.ok { "info" } else { "fail" },
                who: "holder",
                what: "the git state was read",
                why: "the client asked what git says",
                how: "the shared git layer was asked, and it only reads",
                inputs: json!({ "what": what, "path": directory.display().to_string() }),
                outputs: json!({ "git": answer.data }),
                result: json!({}),
            });
            session.write(&record);
            answer_client(session, at, &record);
            Ok(true)
        }
        "workspace" => {
            // The client asks what the shared workspace holds, or asks
            // for a change: the engine is asked, and the engine owns the
            // workspaces, the projects and the context.
            let what = request
                .get("what")
                .and_then(|value| value.as_str())
                .unwrap_or("list")
                .to_string();
            let project = request
                .get("project")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            let name = request
                .get("name")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            let directory = session.workspace_dir.clone();
            let workspace_name = session.workspace.clone();
            let answer = match what.as_str() {
                "create" | "project" | "open" => {
                    workspace::write(&directory, &workspace_name, &what, &name)
                }
                _ => workspace::read(&directory, &workspace_name, &what),
            };
            let record = session.record(Fields {
                kind: if answer.ok { "info" } else { "fail" },
                who: "holder",
                what: "the workspace was read",
                why: "the client asked what the workspace holds",
                how: "the shared workspace engine was asked, and it answered in its own envelope",
                inputs: json!({ "what": what, "name": name, "project": project }),
                outputs: json!({ "workspace": answer.data, "why": answer.reason }),
                result: json!({}),
            });
            session.write(&record);
            answer_client(session, at, &record);
            Ok(true)
        }
        "editor" => {
            // The client asks the editor what it owns: the editor's own
            // server is asked, over the editor's own wire, and the editor's
            // own words come back. The ask is read-only, and the editor's
            // own engine checks that before it runs anything.
            let command: Vec<String> = request
                .get("command")
                .and_then(|value| value.as_array())
                .map(|list| {
                    list.iter()
                        .filter_map(|one| one.as_str().map(|text| text.to_string()))
                        .collect()
                })
                .unwrap_or_default();
            let capability = request
                .get("capability")
                .and_then(|value| value.as_str())
                .unwrap_or("dashboard")
                .to_string();
            let answer = editor::ask(&command, &capability);
            let record = session.record(Fields {
                kind: if answer.ok { "info" } else { "fail" },
                who: "holder",
                what: "the editor was asked",
                why: "the client asked what the editor owns",
                how: "the editor's own server was asked, over its own wire, and it only reads",
                inputs: json!({ "capability": capability, "command": command }),
                outputs: json!({ "editor": answer.data }),
                result: json!({}),
            });
            session.write(&record);
            answer_client(session, at, &record);
            Ok(true)
        }
        "control" => control(session, at, &request),
        "view" => view(session, at, &request),
        "control-result" => control_result(session, at, &request),
        "read" => {
            let since = request.get("since").and_then(|value| value.as_u64()).unwrap_or(0);
            let held = log::Log::records(&session.log_path)?;
            let mut sent = 0u64;
            for record in &held {
                let seq = record.get("seq").and_then(|value| value.as_u64()).unwrap_or(0);
                if seq <= since {
                    continue;
                }
                let mut line = record.to_string();
                line.push('\n');
                if write_to(session.clients[at].fd, line.as_bytes()).is_err() {
                    break;
                }
                sent += 1;
            }
            let done = session.record(Fields {
                kind: "info",
                who: "holder",
                what: "the records were read from the log",
                why: "the client asked for the records",
                how: "the log file was read back and the records after since were sent",
                inputs: json!({ "since": since }),
                outputs: json!({ "sent": sent }),
                result: json!({}),
            });
            session.write(&done);
            // The last answer of this request: the reader knows the records
            // are all there without waiting for the connection to close.
            answer_client(session, at, &done);
            // The client stays: the answer says it is the last one of this
            // request, and the client closes the connection when it is done.
            Ok(true)
        }
        "send" => {
            let data = request.get("data").and_then(|value| value.as_str()).unwrap_or("");
            let wanted_pane = request
                .get("pane")
                .and_then(|value| value.as_str())
                .unwrap_or("");
            let target = match pane_at(session, wanted_pane) {
                Ok(found) => found,
                Err(why) => {
                    let record = session.record(Fields {
                        kind: "fail",
                        who: "holder",
                        what: "the pane took no bytes",
                        why: "there is no pane of that name",
                        how: "the pane was looked for and refused by name",
                        inputs: json!({ "pane": wanted_pane }),
                        outputs: json!({}),
                        result: json!({ "why": why }),
                    });
                    session.write(&record);
                    answer_client(session, at, &record);
                    return Ok(false);
                }
            };
            let pane_name = session.panes[target].name.clone();
            let sent = match session.panes[target].shell.send(data.as_bytes()) {
                Ok(()) => true,
                Err(why) => {
                    let record = session.record(Fields {
                        kind: "fail",
                        who: "holder",
                        what: "the shell took no bytes",
                        why: "the terminal refused the data",
                        how: "the bytes were written to the master",
                        inputs: json!({ "bytes": data.len() }),
                        outputs: json!({}),
                        result: json!({ "why": why }),
                    });
                    session.write(&record);
                    answer_client(session, at, &record);
                    false
                }
            };
            if sent {
                // The command the pane was given: the typed text since the
                // last newline. The log holds it, so a later send can carry
                // the command and what the pane printed after it.
                session.panes[target].typed.push_str(data);
                let typed = session.panes[target].typed.clone();
                let command = match typed.rfind('\n') {
                    Some(at) => Some(typed[..at].to_string()),
                    None => None,
                };
                if let Some(command) = command {
                    let kept = typed.rsplit('\n').next().unwrap_or("").to_string();
                    session.panes[target].typed = kept;
                    let record = session.record(Fields {
                        kind: "command",
                        who: "holder",
                        what: "the pane was given a command",
                        why: "the owner typed it in that pane",
                        how: "the typed text was read up to the newline that ended it",
                        inputs: json!({ "pane": pane_name.clone(), "command": command }),
                        outputs: json!({}),
                        result: json!({}),
                    });
                    session.write(&record);
                }
                let record = session.record(Fields {
                    kind: "info",
                    who: "client",
                    what: "the data went to the shell",
                    why: "the client asked to send",
                    how: "the bytes were written to the terminal",
                    inputs: json!({ "bytes": data.len(), "client": client_name(&request), "pane": pane_name }),
                    outputs: json!({}),
                    result: json!({}),
                });
                session.write(&record);
                answer_client(session, at, &record);
            }
            // The client stays: a screen sends a key and then sends the next.
            Ok(true)
        }
        "send-agent" => {
            // The picked text goes to the agent that is open, in the
            // bundle: the same shape every program sends. The bundle is
            // built here, where the redaction seam is, and the text
            // leaves the multiplexer through the agent's own terminal.
            let selection = request
                .get("selection")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            let target = request
                .get("target")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            let why = request
                .get("why")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            let from = request
                .get("from")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            // The command record: the command the pane was given and what
            // that pane printed after it, read from the log — the truth, and
            // never a copy the screen made by hand.
            let (command, output) = command_record(session, &from);
            let made = bundle::Bundle::make(
                "aiu-multiplexer",
                "aiu-ecosystem",
                &target,
                &selection,
                "",
                "",
                "",
                &why,
            );
            let text = match made {
                Some(bundle) => {
                    let bundle = bundle.carrying(&command, &output);
                    let text = format!("{}\n", bundle.text());
                    // The seam has already been through the bundle; this
                    // asks the seam again, and a text that would still
                    // change is refused by name instead of written to an
                    // agent's terminal.
                    if !bundle::carries_no_secret(&text) {
                        let record = session.record(Fields {
                            kind: "fail",
                            who: "holder",
                            what: "the picked text was not sent",
                            why: "the bundle would carry a secret",
                            how: "the redaction seam was asked again and the text would change",
                            inputs: json!({ "target": target, "from": from }),
                            outputs: json!({}),
                            result: json!({ "why": "the bundle would carry a secret" }),
                        });
                        session.write(&record);
                        answer_client(session, at, &record);
                        return Ok(false);
                    }
                    text
                }
                None => {
                    let record = session.record(Fields {
                        kind: "fail",
                        who: "holder",
                        what: "the picked text was not sent",
                        why: "the bundle could not be made",
                        how: "the redaction seam refused the text",
                        inputs: json!({ "target": target }),
                        outputs: json!({}),
                        result: json!({ "why": "the bundle could not be made" }),
                    });
                    session.write(&record);
                    answer_client(session, at, &record);
                    return Ok(false);
                }
            };
            // The destinations: the multiplexer's own agent and the editor's
            // agent. Both panes run the same agent program, so one bundle
            // serves both and neither is told which one it is.
            let destinations: Vec<usize> = AGENT_PANES
                .iter()
                .filter_map(|name| session.panes.iter().position(|pane| &pane.name == name))
                .collect();
            if destinations.is_empty() {
                let record = session.record(Fields {
                    kind: "fail",
                    who: "holder",
                    what: "the picked text was not sent",
                    why: "there is no agent pane open",
                    how: "the panes were looked for and no agent was found",
                    inputs: json!({ "target": target, "from": from }),
                    outputs: json!({}),
                    result: json!({ "why": "there is no agent pane open" }),
                });
                session.write(&record);
                answer_client(session, at, &record);
                return Ok(false);
            }
            let mut went: Vec<String> = Vec::new();
            for pane_index in destinations {
                let pane_name = session.panes[pane_index].name.clone();
                let sent = session.panes[pane_index].shell.send(text.as_bytes());
                let record = session.record(Fields {
                    kind: if sent.is_ok() { "info" } else { "fail" },
                    who: "holder",
                    what: "the bundle went to the agent",
                    why: "the owner sent the picked text",
                    how: "the bundle was written to the agent's terminal",
                    inputs: json!({ "bytes": text.len(), "pane": pane_name.clone(), "target": target }),
                    outputs: json!({}),
                    result: json!({}),
                });
                session.write(&record);
                if sent.is_ok() {
                    went.push(pane_name);
                }
            }
            let record = session.record(Fields {
                kind: "info",
                who: "holder",
                what: "the bundle went to the agents",
                why: "the owner sent the picked text to the agents",
                how: "the same bundle was written to every agent pane that is open",
                inputs: json!({ "target": target, "from": from, "agents": went.len() }),
                outputs: json!({ "agents": went.join(",") }),
                result: json!({}),
            });
            session.write(&record);
            answer_client(session, at, &record);
            Ok(true)
        }
        "open" => {
            let wanted = request
                .get("name")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            let program = request
                .get("program")
                .and_then(|value| value.as_str())
                .unwrap_or("/bin/sh")
                .to_string();
            let name = if wanted.is_empty() {
                format!("pane-{}", session.panes.len() + 1)
            } else {
                wanted
            };
            if session.panes.iter().any(|pane| pane.name == name) {
                let record = session.record(Fields {
                    kind: "fail",
                    who: "holder",
                    what: "the pane did not open",
                    why: "a pane of that name is already open",
                    how: "the name was looked for among the open panes and refused",
                    inputs: json!({ "pane": name }),
                    outputs: json!({}),
                    result: json!({ "why": format!("a pane named {} is already open", name) }),
                });
                session.write(&record);
                answer_client(session, at, &record);
                return Ok(false);
            }
            let mut args: Vec<String> = request
                .get("args")
                .and_then(|value| value.as_array())
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| item.as_str().map(|word| word.to_string()))
                        .collect()
                })
                .unwrap_or_default();
            // The context: the tail of the pane's own log, asked of the log
            // itself. The screen never copies the text by hand and never
            // scrapes the drawing: the log is the truth.
            if let Some(context) = request.get("context") {
                let pane_of = context
                    .get("pane")
                    .and_then(|value| value.as_str())
                    .unwrap_or("")
                    .to_string();
                let target = context
                    .get("target")
                    .and_then(|value| value.as_str())
                    .unwrap_or("")
                    .to_string();
                let why = context
                    .get("why")
                    .and_then(|value| value.as_str())
                    .unwrap_or("")
                    .to_string();
                // The selection is the text the owner picked on the
                // screen, when the screen picked one. Without a pick the
                // context is the tail of the pane's own log: the log
                // belongs to the holder, and the screen never copies the
                // text by hand.
                let selection = match context.get("selection").and_then(|value| value.as_str()) {
                    Some(picked) => picked.to_string(),
                    None => pane_log_tail(session, &pane_of, 50),
                };
                let made = bundle::Bundle::make(
                    "aiu-multiplexer",
                    "aiu-ecosystem",
                    &target,
                    &selection,
                    "",
                    "",
                    "",
                    &why,
                );
                match made {
                    Some(bundle) => {
                        let text = bundle.text();
                        args.push("--prompt".to_string());
                        args.push(text);
                        // The send is a record: the log says what was sent,
                        // to whom and why, before the pane that carries it
                        // opens.
                        let record = session.record(Fields {
                            kind: "info",
                            who: "client",
                            what: "the context went to the agent",
                            why: "the owner asked for the agent beside this pane",
                            how: "the bundle was built from the pane's log and the pane was opened with it",
                            inputs: json!({ "pane": name.clone(), "program": program.clone(), "client": client_name(&request) }),
                            outputs: json!({ "target": target, "bytes": selection.len() }),
                            result: json!({ "document": bundle.document() }),
                        });
                        session.write(&record);
                    }
                    None => {
                        let record = session.record(Fields {
                            kind: "fail",
                            who: "holder",
                            what: "the agent pane did not open",
                            why: "a send needs a reason",
                            how: "the bundle was refused because the why was blank",
                            inputs: json!({ "pane": name.clone(), "program": program.clone() }),
                            outputs: json!({}),
                            result: json!({ "why": "the why of the send was blank" }),
                        });
                        session.write(&record);
                        answer_client(session, at, &record);
                        return Ok(false);
                    }
                }
            }
            let opened = match shells::Shell::start(&program, &args, session.cols, session.rows) {
                Ok(shell) => shell,
                Err(why) => {
                    let record = session.record(Fields {
                        kind: "fail",
                        who: "holder",
                        what: "the pane did not open",
                        why: "the program could not be started",
                        how: "the terminal refused the program",
                        inputs: json!({ "pane": name, "program": program }),
                        outputs: json!({}),
                        result: json!({ "why": why }),
                    });
                    session.write(&record);
                    answer_client(session, at, &record);
                    return Ok(false);
                }
            };
            let pid = opened.pid;
            let tab = request
                .get("tab")
                .and_then(|value| value.as_str())
                .filter(|value| !value.is_empty())
                .map(|value| value.to_string())
                .unwrap_or_else(|| {
                    session
                        .tabs
                        .first()
                        .cloned()
                        .unwrap_or_else(|| "main".to_string())
                });
            if !session.tabs.contains(&tab) {
                session.tabs.push(tab.clone());
            }
            session.panes.push(Pane {
                name: name.clone(),
                tab: tab.clone(),
                weight: 1,
                args: args.clone(),
                typed: String::new(),
                shell: opened,
            });
            let record = session.record(Fields {
                kind: "info",
                who: "holder",
                what: "a pane opened",
                why: "the client asked for a pane",
                how: "a terminal was opened, the program was started on it, the pane joined the session",
                inputs: json!({ "pane": name, "tab": tab, "program": program, "args": args.len(), "client": client_name(&request) }),
                outputs: json!({ "pid": pid, "panes": session.panes.len() }),
                result: json!({}),
            });
            session.write(&record);
            answer_client(session, at, &record);
            Ok(true)
        }
        "resize" => {
            let cols = request
                .get("cols")
                .and_then(|value| value.as_u64())
                .unwrap_or(0) as u16;
            let rows = request
                .get("rows")
                .and_then(|value| value.as_u64())
                .unwrap_or(0) as u16;
            if cols == 0 || rows == 0 {
                let record = session.record(Fields {
                    kind: "fail",
                    who: "holder",
                    what: "the window did not change",
                    why: "the size asked for is not a size",
                    how: "the columns and the rows were read and refused",
                    inputs: json!({ "cols": cols, "rows": rows }),
                    outputs: json!({}),
                    result: json!({ "why": "a window needs columns and rows".to_string() }),
                });
                session.write(&record);
                answer_client(session, at, &record);
                return Ok(false);
            }
            // One window for the whole session: every pane — a shell or an
            // editor — is told the same size, so what the owner sees in one
            // pane is what the other pane draws.
            let mut told: Vec<String> = Vec::new();
            for pane in &session.panes {
                let set = tty::set_window_size(pane.shell.master, cols, rows);
                if set.is_ok() {
                    unsafe {
                        libc::kill(-pane.shell.pid, libc::SIGWINCH);
                    }
                    told.push(pane.name.clone());
                }
            }
            session.cols = cols;
            session.rows = rows;
            let record = session.record(Fields {
                kind: "info",
                who: "holder",
                what: "the window changed",
                why: "the client told the session the size of the terminal",
                how: "every pane's terminal was resized and every program was told to redraw",
                inputs: json!({ "cols": cols, "rows": rows, "client": client_name(&request) }),
                outputs: json!({ "panes": Value::Array(
                    told.iter().map(|name| Value::from(name.clone())).collect::<Vec<Value>>()
                ) }),
                result: json!({}),
            });
            session.write(&record);
            answer_client(session, at, &record);
            Ok(true)
        }
        "rename" => {
            let kind = request
                .get("kind")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            let name = request
                .get("name")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            let to = request
                .get("to")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            if name.is_empty() || to.is_empty() {
                let record = session.record(Fields {
                    kind: "fail",
                    who: "holder",
                    what: "the name did not change",
                    why: "a rename needs the old name and the new one",
                    how: "the names were read and refused",
                    inputs: json!({ "kind": kind, "name": name, "to": to }),
                    outputs: json!({}),
                    result: json!({ "why": "a rename needs the old name and the new one".to_string() }),
                });
                session.write(&record);
                answer_client(session, at, &record);
                return Ok(true);
            }
            let mut changed: Vec<String> = Vec::new();
            if kind == "tab" {
                for tab in session.tabs.iter_mut() {
                    if *tab == name {
                        *tab = to.clone();
                        changed.push(name.clone());
                    }
                }
                for pane in session.panes.iter_mut() {
                    if pane.tab == name {
                        pane.tab = to.clone();
                    }
                }
            } else {
                for pane in session.panes.iter_mut() {
                    if pane.name == name {
                        pane.name = to.clone();
                        changed.push(name.clone());
                    }
                }
            }
            if changed.is_empty() {
                let record = session.record(Fields {
                    kind: "fail",
                    who: "holder",
                    what: "the name did not change",
                    why: "there is nothing of that name to rename",
                    how: "the name was looked for and refused by name",
                    inputs: json!({ "kind": kind, "name": name, "to": to }),
                    outputs: json!({}),
                    result: json!({ "why": format!("there is no {} named {}", kind, name) }),
                });
                session.write(&record);
                answer_client(session, at, &record);
                return Ok(true);
            }
            let record = session.record(Fields {
                kind: "info",
                who: "holder",
                what: "the name changed",
                why: "the client asked for another name",
                how: "the name was looked for and replaced",
                inputs: json!({ "kind": kind, "name": name, "to": to, "client": client_name(&request) }),
                outputs: json!({ "renamed": Value::Array(
                    changed.iter().map(|n| Value::from(n.clone())).collect::<Vec<Value>>()
                ) }),
                result: json!({}),
            });
            session.write(&record);
            answer_client(session, at, &record);
            Ok(true)
        }
        "close" => {
            let kind = request
                .get("kind")
                .and_then(|value| value.as_str())
                .unwrap_or("pane")
                .to_string();
            let name = request
                .get("name")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .to_string();
            let mut closed: Vec<String> = Vec::new();
            if kind == "tab" {
                for pane in session.panes.iter_mut() {
                    if pane.tab == name {
                        unsafe {
                            libc::kill(pane.shell.pid, libc::SIGTERM);
                        }
                        closed.push(pane.name.clone());
                    }
                }
                session.panes.retain(|pane| pane.tab != name);
                session.tabs.retain(|tab| *tab != name);
            } else {
                for pane in session.panes.iter_mut() {
                    if pane.name == name {
                        unsafe {
                            libc::kill(pane.shell.pid, libc::SIGTERM);
                        }
                        closed.push(pane.name.clone());
                    }
                }
                session.panes.retain(|pane| pane.name != name);
            }
            let record = session.record(Fields {
                kind: "info",
                who: "holder",
                what: "it closed",
                why: "the client asked for it to close",
                how: "the programs were told to end and the panes were let go",
                inputs: json!({ "kind": kind, "name": name, "client": client_name(&request) }),
                outputs: json!({ "closed": Value::Array(
                    closed.iter().map(|n| Value::from(n.clone())).collect::<Vec<Value>>()
                ) }),
                result: json!({}),
            });
            session.write(&record);
            answer_client(session, at, &record);
            Ok(true)
        }
        other => {
            let record = session.record(Fields {
                kind: "fail",
                who: "holder",
                what: "the request is not one this holder knows",
                why: "the op on the wire is not in the set",
                how: "the op was read and refused by name",
                inputs: json!({ "op": other }),
                outputs: json!({}),
                result: json!({
                    "ops": [
                        "attach",
                        "detach",
                        "read",
                        "state",
                        "send",
                        "open",
                        "control",
                        "view",
                        "control-result"
                    ]
                }),
            });
            answer_client(session, at, &record);
            Ok(false)
        }
    }
}

/// control is the agent's door into the screen: the words the agent sent,
/// and the screen's answer. A change needs the human's token, and the holder
/// checks it itself (rule 07): the caller's word is not taken for what it
/// does.
///
/// The holder holds no screen of its own. The words run on the owner's own
/// screen, so the agent and the owner drive the same code.
fn control(session: &mut Session, at: usize, request: &Value) -> Result<bool, String> {
    let id = request
        .get("id")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string();
    let words: Vec<String> = request
        .get("words")
        .and_then(|value| value.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|one| one.as_str().map(|text| text.to_string()))
                .collect()
        })
        .unwrap_or_default();
    let given = request
        .get("confirm")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string();
    if !session.token_matches(&given) {
        let record = session.record(Fields {
            kind: "fail",
            who: "holder",
            what: "the agent's change was refused",
            why: "a change needs the human's token, and it was refused",
            how: "the token was compared with the session's own token",
            inputs: json!({ "id": id, "words": words }),
            outputs: json!({}),
            result: json!({
                "rule": "rule 07: read is free, a change needs the human's token"
            }),
        });
        session.write(&record);
        answer_client(session, at, &record);
        return Ok(true);
    }
    ask_screen(session, at, &id, &words, "control")
}

/// view is the agent's read of the screen: what the owner sees. A read is
/// free, so it needs no token.
fn view(session: &mut Session, at: usize, request: &Value) -> Result<bool, String> {
    let id = request
        .get("id")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string();
    ask_screen(session, at, &id, &[], "view")
}

/// ask_screen hands the agent's request to the screen and waits for the
/// screen's answer: the request is remembered by its id, and the answer
/// goes back to the client that asked.
fn ask_screen(
    session: &mut Session,
    at: usize,
    id: &str,
    words: &[String],
    kind: &str,
) -> Result<bool, String> {
    let screen = match session.screen_client() {
        Some(fd) => fd,
        None => {
            let record = session.record(Fields {
                kind: "fail",
                who: "holder",
                what: "the agent's request was refused",
                why: "no screen is attached to this session, so there is nothing to drive",
                how: "the clients of the session were looked at, and none of them is a screen",
                inputs: json!({ "id": id, "words": words }),
                outputs: json!({}),
                result: json!({
                    "rule": "the agent drives the owner's own screen; without one there is nothing to drive"
                }),
            });
            session.write(&record);
            answer_client(session, at, &record);
            return Ok(true);
        }
    };
    let requester_fd = session.clients[at].fd;
    session.pending.push(Pending {
        id: id.to_string(),
        requester_fd,
    });
    let asked = json!({
        "kind": kind,
        "who": "agent",
        "inputs": { "id": id, "words": words },
        "outputs": {},
        "result": {}
    });
    let mut line = asked.to_string();
    line.push('\n');
    if let Err(why) = write_to(screen, line.as_bytes()) {
        // The screen did not take the request: it comes off the list and the
        // agent is told, rather than left waiting for an answer that will
        // never come.
        session.pending.pop();
        let record = session.record(Fields {
            kind: "fail",
            who: "holder",
            what: "the agent's request was refused",
            why: "the screen did not take the request",
            how: "the request was written to the screen's wire, and the write failed",
            inputs: json!({ "id": id, "words": words }),
            outputs: json!({}),
            result: json!({ "why": why }),
        });
        session.write(&record);
        answer_client(session, at, &record);
    }
    Ok(true)
}

/// control_result is the screen's answer to the agent's request: the id of
/// the request and what the screen did. The answer goes to the client that
/// asked, and the request is off the list.
fn control_result(session: &mut Session, _at: usize, request: &Value) -> Result<bool, String> {
    let id = request
        .get("id")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string();
    let data = request.get("data").cloned().unwrap_or(json!({}));
    let found = match session.pending.iter().position(|pending| pending.id == id) {
        Some(at) => at,
        None => return Ok(true),
    };
    let pending = session.pending.remove(found);
    let requester = match session
        .clients
        .iter()
        .position(|client| client.fd == pending.requester_fd)
    {
        Some(at) => at,
        None => return Ok(true),
    };
    let record = session.record(Fields {
        kind: "info",
        who: "holder",
        what: "the agent's request was answered",
        why: "the screen ran the words the agent sent",
        how: "the words ran on the owner's own screen, and the screen's answer came back",
        inputs: json!({ "id": id }),
        outputs: json!({ "data": data }),
        result: json!({}),
    });
    session.write(&record);
    answer_client(session, requester, &record);
    Ok(true)
}

/// attach answers a client that wants to watch the session. The contracts are
/// exchanged before anything else, and a mismatch refuses by name.
fn attach(session: &mut Session, at: usize, request: &Value) -> Result<bool, String> {
    let client_event = request
        .get("event-contract")
        .and_then(|value| value.as_str())
        .unwrap_or("");
    let client_holder = request
        .get("holder-contract")
        .and_then(|value| value.as_str())
        .unwrap_or("");

    if client_event != EVENT_CONTRACT || client_holder != HOLDER_CONTRACT {
        let record = session.record(Fields {
            kind: "fail",
            who: "holder",
            what: "the client and the holder do not agree on the contract",
            why: "the versions exchanged at attach differ",
            how: "the two versions were compared and the attach was refused by name",
            inputs: json!({
                "client-event-contract": client_event,
                "client-holder-contract": client_holder
            }),
            outputs: json!({
                "holder-event-contract": EVENT_CONTRACT,
                "holder-holder-contract": HOLDER_CONTRACT
            }),
            result: json!({
                "safe-path": "finish the session and restart the holder, or run the old client"
            }),
        });
        session.write(&record);
        answer_client(session, at, &record);
        return Ok(false);
    }

    session.clients[at].attached = true;
    // The screen says what it is: the agent's words run on the owner's own
    // screen, and nowhere else.
    let role = request
        .get("role")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string();
    session.clients[at].role = role;
    let record = session.state("the client attached and the contracts agree");
    session.write(&record);
    // The answer is not the last one: the client stays and watches what the
    // session says next.
    answer_client_more(session, at, &record);
    Ok(true)
}

/// client_name answers the name a client gave, or a plain one.
fn client_name(request: &Value) -> String {
    request
        .get("client")
        .and_then(|value| value.as_str())
        .unwrap_or("a client")
        .to_string()
}

/// Options are the holder's arguments: the state directory is one of them, so
/// no environment variable is read for it.
struct Options {
    state_dir: PathBuf,
    shell: String,
    layout: Option<PathBuf>,
    cols: u16,
    rows: u16,
    /// workspace_dir is where the shared workspace engine keeps its files:
    /// it is an argument, and no environment variable names it.
    workspace_dir: PathBuf,
    /// workspace is the workspace this session works on, when the owner
    /// names one. Empty means the only one there is.
    workspace: String,
}

impl Options {
    fn read(args: &[String]) -> Result<Options, String> {
        let mut state_dir: Option<PathBuf> = None;
        let mut shell = "/bin/sh".to_string();
        let mut layout: Option<PathBuf> = None;
        let mut cols: u16 = 80;
        let mut rows: u16 = 24;
        let mut workspace_dir: Option<PathBuf> = None;
        let mut workspace = String::new();
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
                "--shell" => {
                    shell = value;
                    at += 2;
                }
                "--layout" => {
                    layout = Some(PathBuf::from(value));
                    at += 2;
                }
                "--workspace-dir" => {
                    workspace_dir = Some(PathBuf::from(value));
                    at += 2;
                }
                "--workspace" => {
                    workspace = value;
                    at += 2;
                }
                "--cols" => {
                    cols = value
                        .parse()
                        .map_err(|_| "--cols wants a number of columns".to_string())?;
                    at += 2;
                }
                "--rows" => {
                    rows = value
                        .parse()
                        .map_err(|_| "--rows wants a number of rows".to_string())?;
                    at += 2;
                }
                "--help" => {
                    println!(
                        "holder --state-dir DIR [--shell PROGRAM] [--layout FILE] [--cols N] [--rows N] [--workspace-dir DIR] [--workspace NAME]"
                    );
                    std::process::exit(0);
                }
                other => return Err(format!("{} is not an option this holder knows", other)),
            }
        }
        let state_dir = state_dir.ok_or("the holder needs --state-dir")?;
        let workspace_dir = workspace_dir.unwrap_or_else(|| state_dir.join("workspace"));
        Ok(Options {
            state_dir,
            shell,
            layout,
            cols,
            rows,
            workspace_dir,
            workspace,
        })
    }
}

/// bind opens the session's socket and listens on it.
fn bind(path: &Path) -> Result<c_int, String> {
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err("this phone cannot make a unix socket".to_string());
    }
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    let bytes = path.as_os_str().as_bytes();
    if bytes.len() >= address.sun_path.len() {
        close(fd);
        return Err(format!(
            "the socket path {} is too long for this phone",
            path.display()
        ));
    }
    for (at, byte) in bytes.iter().enumerate() {
        address.sun_path[at] = *byte as libc::c_char;
    }
    let length =
        (std::mem::size_of::<libc::sa_family_t>() + bytes.len() + 1) as libc::socklen_t;
    let put = unsafe {
        libc::bind(
            fd,
            &address as *const libc::sockaddr_un as *const libc::sockaddr,
            length,
        )
    };
    if put != 0 {
        close(fd);
        return Err(format!("the socket {} cannot be bound", path.display()));
    }
    if unsafe { libc::listen(fd, 8) } != 0 {
        close(fd);
        return Err(format!("the socket {} cannot listen", path.display()));
    }
    Ok(fd)
}

/// connect opens a connection to a socket that is already there.
fn connect(path: &Path) -> Result<c_int, String> {
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
        return Err(format!("the socket {} refused the connection", path.display()));
    }
    Ok(fd)
}

/// read_from waits for bytes and answers how many came.
fn read_from(fd: c_int, buffer: &mut [u8]) -> Result<usize, String> {
    let got = unsafe { libc::read(fd, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
    if got >= 0 {
        Ok(got as usize)
    } else {
        Err(format!("read from fd {} failed", fd))
    }
}

/// write_to puts bytes on a descriptor and answers when they are all in.
fn write_to(fd: c_int, bytes: &[u8]) -> Result<(), String> {
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

/// answer_client puts one record on one client's wire and says so when it
/// cannot: a client that gets no answer must hear why.
///
/// The answer is marked as the last one of that request, so a reader knows
/// when the answer is complete without waiting for the connection to close.
fn answer_client(session: &mut Session, at: usize, record: &Value) {
    let fd = session.clients[at].fd;
    let mut answer = record.clone();
    if let Some(result) = answer.get_mut("result").and_then(|value| value.as_object_mut()) {
        result.insert("final".to_string(), Value::Bool(true));
    }
    if let Err(why) = write_to(fd, record_line(&answer).as_bytes()) {
        eprintln!("holder: the client on fd {} was not answered: {}", fd, why);
    }
}

/// answer_client_more puts one record on a client's wire without marking it
/// as the last one: the client stays and watches what comes next.
fn answer_client_more(session: &mut Session, at: usize, record: &Value) {
    let fd = session.clients[at].fd;
    if let Err(why) = write_to(fd, record_line(record).as_bytes()) {
        eprintln!("holder: the client on fd {} was not answered: {}", fd, why);
    }
}

/// record_line answers one record as it goes on the wire: one JSON object,
/// one line. The newline is what makes a line a line for the reader on the
/// other end.
fn record_line(record: &Value) -> String {
    let mut text = record.to_string();
    text.push('\n');
    text
}

/// close closes one descriptor and says nothing.
fn close(fd: c_int) {
    if fd >= 0 {
        unsafe {
            libc::close(fd);
        }
    }
}

/// utc_now answers the wall clock as a person reads it, without a date
/// library: the kernel holds the broken-down time and this formats it.
fn utc_now() -> String {
    let now = unsafe { libc::time(std::ptr::null_mut()) };
    let mut parts: libc::tm = unsafe { std::mem::zeroed() };
    unsafe {
        libc::gmtime_r(&now, &mut parts);
    }
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        parts.tm_year + 1900,
        parts.tm_mon + 1,
        parts.tm_mday,
        parts.tm_hour,
        parts.tm_min,
        parts.tm_sec
    )
}
