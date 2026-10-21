// One job: the session's wire — one JSON object per line, both ways.
//
// This is the client half of the protocol the holder serves. It lives in the
// holder area because the holder owns the protocol; the screens above it
// (the human client, the agent's MCP server) speak it through this file and
// do not each write their own.

use serde_json::Value;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// connect opens a connection to a holder's socket.
pub fn connect(path: &Path) -> Result<libc::c_int, String> {
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

/// ask sends one request object and answers nothing: the holder answers on
/// the same wire.
pub fn ask(fd: libc::c_int, request: &Value) -> Result<(), String> {
    let mut line = request.to_string();
    line.push('\n');
    write(fd, line.as_bytes())
}

/// read waits for bytes and answers how many came; 0 means the other side is
/// gone.
pub fn read(fd: libc::c_int, buffer: &mut [u8]) -> Result<usize, String> {
    let got = unsafe { libc::read(fd, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
    if got >= 0 {
        Ok(got as usize)
    } else {
        Err(format!("read from fd {} failed", fd))
    }
}

/// write puts bytes on a descriptor and answers when they are all in.
pub fn write(fd: libc::c_int, bytes: &[u8]) -> Result<(), String> {
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
pub fn close(fd: libc::c_int) {
    if fd >= 0 {
        unsafe {
            libc::close(fd);
        }
    }
}

/// wait_for_socket waits for a holder's socket to appear, and the wait ends
/// on the filesystem event that creates it — never on a clock. The agent's
/// server does not use it: a session it is asked about is already held.
#[allow(dead_code)]
pub fn wait_for_socket(path: &Path) -> Result<(), String> {
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
        Err(format!("the holder's socket {} never came", path.display()))
    }
}

/// holder_is_gone answers whether the holder that wrote its pid into this
/// state directory is no longer there.
#[allow(dead_code)]
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
