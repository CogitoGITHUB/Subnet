// One job: what works under proot is measured, never assumed.
//
// The holder asks this file what the kernel actually did, and writes the answer
// into the session log as a record. A capability this phone does not have is
// then a fact in the log, not a promise in a document.

use crate::tty;

/// Measured is what one terminal actually answered when it was opened, made
/// raw and sized: the facts the holder logs, and nothing it hopes for.
pub struct Measured {
    pub pty_open: bool,
    pub raw_mode: bool,
    pub sized: bool,
    pub cols: u16,
    pub rows: u16,
    pub slave: String,
}

/// of_terminal takes the terminal that was opened and reads the kernel back:
/// the slave name it answered, whether raw mode took, and the size it holds.
pub fn of_terminal(fd: libc::c_int, wanted: (u16, u16), slave: &str) -> Measured {
    let held = tty::window_size(fd);
    let (cols, rows) = held.unwrap_or((0, 0));
    Measured {
        pty_open: fd >= 0 && !slave.is_empty(),
        raw_mode: tty::is_raw(fd),
        sized: cols == wanted.0 && rows == wanted.1,
        cols,
        rows,
        slave: slave.to_string(),
    }
}

/// record answers the measured facts as the fields of one log record, so the
/// log says what the phone did before it says anything else.
pub fn record(measured: &Measured) -> Vec<(&'static str, serde_json::Value)> {
    let mut fields: Vec<(&'static str, serde_json::Value)> = Vec::new();
    fields.push(("pty", serde_json::Value::Bool(measured.pty_open)));
    fields.push(("raw", serde_json::Value::Bool(measured.raw_mode)));
    fields.push(("sized", serde_json::Value::Bool(measured.sized)));
    fields.push(("cols", serde_json::Value::from(measured.cols)));
    fields.push(("rows", serde_json::Value::from(measured.rows)));
    fields.push(("slave", serde_json::Value::from(measured.slave.clone())));
    fields
}
