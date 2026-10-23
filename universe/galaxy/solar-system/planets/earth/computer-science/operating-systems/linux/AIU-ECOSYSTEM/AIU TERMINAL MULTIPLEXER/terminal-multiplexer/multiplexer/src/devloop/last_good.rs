// One job: the last good bake — the path of the last baked config that passed
// its check, the way to record a new one, and the way to read one back.
//
// A bake that goes wrong must never ship: the last good stays the last good,
// and the bad one is kept beside it so the owner can look at it. The rule is
// one line: the last good bake is kept.
//
// This file does not decide what good is. The bake asks that question — it
// reads its own file back — and calls keep_last_good only when the answer is
// yes, exactly as the editor's last-good area leaves the check to its caller.

use std::path::{Path, PathBuf};

/// RECORD is the file in the state directory that holds the path of the last
/// good bake: one line, the path.
pub const RECORD: &str = "last-good";

/// last_good answers the path of the last good bake, or None when there has
/// never been one.
pub fn last_good(state_dir: &Path) -> Option<PathBuf> {
    let text = std::fs::read_to_string(state_dir.join(RECORD)).ok()?;
    let path = text.trim();
    if path.is_empty() {
        None
    } else {
        Some(PathBuf::from(path))
    }
}

/// keep_last_good records a path as the last good bake. Called only when the
/// bake has already been found good.
pub fn keep_last_good(state_dir: &Path, path: &Path) -> Result<(), String> {
    std::fs::create_dir_all(state_dir).map_err(|why| {
        format!(
            "the state directory {} cannot be made: {}",
            state_dir.display(),
            why
        )
    })?;
    let record = state_dir.join(RECORD);
    let text = format!("{}\n", path.display());
    std::fs::write(&record, text.as_bytes())
        .map_err(|why| format!("{} cannot be written: {}", record.display(), why))
}

/// read_text reads a recorded path's file back, so a caller holds the text of
/// the bake it has just recorded, or of the last good one.
pub fn read_text(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path)
        .map_err(|why| format!("{} cannot be read: {}", path.display(), why))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// scratch answers a state directory of this test's own.
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mux-last-good-{}-{}", std::process::id(), name));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("the scratch directory is made");
        dir
    }

    #[test]
    fn with_no_record_there_is_no_last_good() {
        let dir = scratch("none");
        assert_eq!(last_good(&dir), None);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_recorded_path_answers_as_the_last_good() {
        let dir = scratch("recorded");
        let baked = dir.join("baked").join("config.json");
        keep_last_good(&dir, &baked).expect("the record is written");
        assert_eq!(last_good(&dir), Some(baked));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_recorded_path_is_read_back_as_the_text_it_holds() {
        let dir = scratch("read-back");
        let baked = dir.join("baked").join("config.json");
        fs::create_dir_all(baked.parent().expect("the baked directory is under the state"))
            .expect("the baked directory is made");
        fs::write(&baked, b"{\"level\": 1}\n").expect("the bake is written");
        keep_last_good(&dir, &baked).expect("the record is written");
        let path = last_good(&dir).expect("there is a last good");
        let text = read_text(&path).expect("the recorded file reads back");
        assert_eq!(text, "{\"level\": 1}\n");
        let _ = fs::remove_dir_all(&dir);
    }
}
