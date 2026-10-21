// One job: the store — the files that hold the workspaces, the lock that
// keeps one writer at a time, and the write that never leaves half a file.
//
// The state directory is an argument. Nothing here reads an environment
// variable, and nothing here waits on a clock: the lock is held by the
// kernel while a write happens, and the wait for it ends when the holder
// lets go.

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

use crate::model::State;

/// Store is the set of workspaces on disk.
pub struct Store {
    root: PathBuf,
}

impl Store {
    /// open makes the store ready and answers it. The directory is made if
    /// it is not there: a store that cannot be made says why.
    pub fn open(root: &Path) -> Result<Store, String> {
        let workspaces = root.join("workspaces");
        fs::create_dir_all(&workspaces).map_err(|why| {
            format!(
                "the workspace directory {} cannot be made: {}",
                workspaces.display(),
                why
            )
        })?;
        Ok(Store {
            root: root.to_path_buf(),
        })
    }

    /// root answers where the store keeps its files.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// workspace_ids answers the workspaces the store holds.
    pub fn workspace_ids(&self) -> Result<Vec<String>, String> {
        let mut ids: Vec<String> = Vec::new();
        let entries = fs::read_dir(self.root.join("workspaces")).map_err(|why| {
            format!("the workspaces cannot be listed: {}", why)
        })?;
        for entry in entries {
            let entry = entry.map_err(|why| format!("a workspace cannot be read: {}", why))?;
            if entry.path().is_dir() {
                ids.push(entry.file_name().to_string_lossy().to_string());
            }
        }
        ids.sort();
        Ok(ids)
    }

    /// workspace_dir answers where one workspace keeps its files.
    fn workspace_dir(&self, workspace: &str) -> PathBuf {
        self.root.join("workspaces").join(workspace)
    }

    /// read answers the state of one workspace, or nothing when it is not
    /// there. It takes no lock: the write renames, so a reader sees the
    /// old file or the new one, and never half of one.
    pub fn read(&self, workspace: &str) -> Result<Option<State>, String> {
        let path = self.workspace_dir(workspace).join("state.json");
        match fs::read_to_string(&path) {
            Ok(text) => {
                let value: serde_json::Value = serde_json::from_str(&text).map_err(|why| {
                    format!("the workspace file {} cannot be read: {}", path.display(), why)
                })?;
                Ok(Some(State::from_json(&value)?))
            }
            Err(why) if why.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(why) => Err(format!(
                "the workspace file {} cannot be read: {}",
                path.display(),
                why
            )),
        }
    }

    /// write puts the state on disk: a write beside the old file, then a
    /// rename over it. One writer at a time: the lock is held while the
    /// write happens and released when it is done.
    pub fn write(&self, workspace: &str, state: &State) -> Result<(), String> {
        let dir = self.workspace_dir(workspace);
        fs::create_dir_all(&dir).map_err(|why| {
            format!("the workspace directory {} cannot be made: {}", dir.display(), why)
        })?;
        let _lock = Lock::take(dir.join("lock"))?;
        let text = state.to_json().to_string();
        let temp = dir.join("state.json.new");
        {
            let mut file = File::create(&temp).map_err(|why| {
                format!("the workspace file {} cannot be written: {}", temp.display(), why)
            })?;
            file.write_all(text.as_bytes()).map_err(|why| {
                format!("the workspace file {} cannot be written: {}", temp.display(), why)
            })?;
            file.sync_all().map_err(|why| {
                format!("the workspace file {} cannot be flushed: {}", temp.display(), why)
            })?;
        }
        fs::rename(&temp, dir.join("state.json")).map_err(|why| {
            format!(
                "the workspace file {} cannot be put in place: {}",
                dir.join("state.json").display(),
                why
            )
        })
    }

    /// remove forgets one workspace and its files. It closes no terminal,
    /// deletes no file outside the store, and touches no other program.
    pub fn remove(&self, workspace: &str) -> Result<(), String> {
        let dir = self.workspace_dir(workspace);
        if !dir.exists() {
            return Err(format!("the workspace {} is not there", workspace));
        }
        fs::remove_dir_all(&dir).map_err(|why| {
            format!("the workspace {} cannot be forgotten: {}", workspace, why)
        })
    }
}

/// Lock is one held lock: the file that holds it, and the kernel's promise
/// that only one writer holds it at a time.
struct Lock {
    file: File,
}

impl Lock {
    /// take takes the lock for a target file, and waits for it while
    /// another writer holds it.
    fn take(path: PathBuf) -> Result<Lock, String> {
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&path)
            .map_err(|why| {
                format!("the lock {} cannot be opened: {}", path.display(), why)
            })?;
        let held = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        if held != 0 {
            return Err(format!(
                "the lock {} cannot be taken: {}",
                path.display(),
                std::io::Error::last_os_error()
            ));
        }
        Ok(Lock { file })
    }
}

impl Drop for Lock {
    fn drop(&mut self) {
        // Closing the file lets the lock go: the kernel does it, and there
        // is nothing to poll.
        let _ = unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{now_stamp, Workspace};

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("workspace-store-{}", name));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    fn state(name: &str) -> State {
        State {
            version: 1,
            workspace: Workspace {
                id: "w1".to_string(),
                name: name.to_string(),
                created: now_stamp(),
                modified: now_stamp(),
            },
            projects: Vec::new(),
            resources: Vec::new(),
            presentations: Vec::new(),
            context: crate::model::Context {
                project: String::new(),
                resources: Vec::new(),
                notes: serde_json::Map::new(),
            },
            applications: serde_json::Map::new(),
            operations: Vec::new(),
        }
    }

    #[test]
    fn a_state_survives_the_store_being_opened_again() {
        let dir = temp_dir("survive");
        let store = Store::open(&dir).expect("the store opens");
        store.write("w1", &state("the work")).expect("the state is written");
        let again = Store::open(&dir).expect("the store opens again");
        let read = again.read("w1").expect("the state is read").expect("it is there");
        assert_eq!(read.workspace.name, "the work");
        assert_eq!(read.version, 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_workspace_that_is_not_there_reads_as_nothing() {
        let dir = temp_dir("missing");
        let store = Store::open(&dir).expect("the store opens");
        assert!(store.read("w9").expect("the read answers").is_none());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_store_lists_the_workspaces_it_holds() {
        let dir = temp_dir("list");
        let store = Store::open(&dir).expect("the store opens");
        store.write("w2", &state("second")).expect("the state is written");
        store.write("w1", &state("first")).expect("the state is written");
        assert_eq!(store.workspace_ids().expect("the list answers"), vec!["w1", "w2"]);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn removing_a_workspace_takes_only_the_store_files() {
        let dir = temp_dir("remove");
        let store = Store::open(&dir).expect("the store opens");
        store.write("w1", &state("the work")).expect("the state is written");
        store.remove("w1").expect("the workspace is forgotten");
        assert!(store.workspace_ids().expect("the list answers").is_empty());
        assert!(store.remove("w1").is_err(), "it is gone once");
        let _ = fs::remove_dir_all(&dir);
    }
}
