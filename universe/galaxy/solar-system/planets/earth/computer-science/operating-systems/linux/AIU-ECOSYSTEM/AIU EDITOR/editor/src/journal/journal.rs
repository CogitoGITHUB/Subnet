// One job: the journal — every edit appended as it happens, in order, and
// replayable after a crash (rule 01). The journal is a file with one line
// per record. The saved file and the journal together are the state: the
// file holds the saved text, the journal holds the work not saved yet.
//
// The record is one line of the editor's own shape, not JSON: the journal
// belongs to the editor, not to the wire. A record is either
// "save" or "insert " followed by the text, with a newline written "\\n",
// a tab written "\\t", a carriage return written "\\r" and a backslash
// written "\\\\", so a record always stays on one line.

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};

/// append_record adds one record to the journal as one line and answers
/// how many records the journal holds now.
pub fn append_record(path: &str, record: &str) -> usize {
    let mut file = match OpenOptions::new().create(true).append(true).open(path) {
        Ok(open) => open,
        Err(why) => panic!("the journal cannot be opened: {}", why),
    };
    if let Err(why) = writeln!(file, "{}", record) {
        panic!("the journal cannot be written: {}", why);
    }
    if let Err(why) = file.flush() {
        panic!("the journal cannot be flushed: {}", why);
    }
    records(path).len()
}

/// records answers the journal's lines, in the order they were written.
pub fn records(path: &str) -> Vec<String> {
    let mut file = match File::open(path) {
        Ok(open) => open,
        Err(_) => return Vec::new(),
    };
    let mut text = String::new();
    if file.read_to_string(&mut text).is_err() {
        return Vec::new();
    }
    text.lines().map(|line| line.to_string()).collect()
}

/// clear empties the journal: the file on disk now holds the work.
pub fn clear(path: &str) {
    let _ = std::fs::write(path, "");
}

/// replay puts the journal's edits back onto the text, and answers the
/// text as it was before the crash. The records are read in the order
/// they were written, and each one says where it happened, so the text
/// comes back exactly. A record the replay does not know is skipped: the
/// replay reads what the journal says and never guesses.
pub fn replay(text: &str, records: &[String]) -> String {
    let mut grown = text.to_string();
    for record in records {
        if let Some((at, more)) = insert_at_text(record) {
            grown.insert_str(at.min(grown.len()), &more);
        } else if let Some((at, count)) = delete_at_text(record) {
            let to = at.saturating_add(count).min(grown.len());
            let at = at.min(grown.len());
            grown = format!("{}{}", &grown[..at], &grown[to..]);
        } else if let Some(more) = insert_text(record) {
            grown.push_str(&more);
        }
    }
    grown
}

/// insert_text reads the text of one insert record and answers it, and
/// answers nothing when the record is not an insert. This is the first
/// shape of the record: the text goes at the end.
fn insert_text(record: &str) -> Option<String> {
    let rest = record.strip_prefix("insert ")?;
    Some(unescape(rest))
}

/// insert_at_text reads the place and the text of one insert-at record,
/// and answers nothing when the record is not one.
fn insert_at_text(record: &str) -> Option<(usize, String)> {
    let rest = record.strip_prefix("insert-at ")?;
    let (at, text) = rest.split_once(' ')?;
    Some((at.parse().ok()?, unescape(text)))
}

/// delete_at_text reads the place and the count of one delete-at record,
/// and answers nothing when the record is not one.
fn delete_at_text(record: &str) -> Option<(usize, usize)> {
    let rest = record.strip_prefix("delete-at ")?;
    let (at, count) = rest.split_once(' ')?;
    Some((at.parse().ok()?, count.parse().ok()?))
}

/// escape writes one text so it always stays on one line.
pub fn escape(text: &str) -> String {
    let mut out = String::new();
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            _ => out.push(c),
        }
    }
    out
}

/// unescape reads one escaped text back.
pub fn unescape(text: &str) -> String {
    let mut out = String::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some('r') => out.push('\r'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}
