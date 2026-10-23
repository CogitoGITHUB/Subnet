// One job: the session's log — one JSON record per line, flushed per record.
//
// The log IS the record (rule 01): a holder that is killed leaves a readable
// prefix and never a torn record, because every record is written whole and
// flushed before the holder moves on (D-006).

use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;

/// Log is one session's append-only log file.
pub struct Log {
    file: std::fs::File,
    written: u64,
}

impl Log {
    /// open opens the log for appending, making the file when it is not there
    /// yet. A log that cannot be opened is an error the caller names.
    pub fn open(path: &Path) -> Result<Log, String> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|why| format!("the log {} cannot be opened: {}", path.display(), why))?;
        Ok(Log { file, written: 0 })
    }

    /// append writes one record as one line and flushes it, so the record is
    /// on disk before the holder does anything else.
    pub fn append(&mut self, record: &serde_json::Value) -> Result<(), String> {
        let mut line = record.to_string();
        line.push('\n');
        self.file
            .write_all(line.as_bytes())
            .map_err(|why| format!("the record cannot be written to the log: {}", why))?;
        self.file
            .flush()
            .map_err(|why| format!("the record cannot be flushed to the log: {}", why))?;
        self.written += 1;
        Ok(())
    }

    /// records answers every record the log file holds, oldest first, read
    /// back from the file: what the log says is what the file holds.
    pub fn records(path: &Path) -> Result<Vec<serde_json::Value>, String> {
        let body = std::fs::read_to_string(path)
            .map_err(|why| format!("the log {} cannot be read: {}", path.display(), why))?;
        let mut held: Vec<serde_json::Value> = Vec::new();
        for line in body.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            match serde_json::from_str::<serde_json::Value>(trimmed) {
                Ok(value) => held.push(value),
                Err(why) => {
                    return Err(format!(
                        "the log holds a line that is not a record: {}",
                        why
                    ))
                }
            }
        }
        Ok(held)
    }
}
