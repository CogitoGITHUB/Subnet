// One job: the workspace engine — the one model, the one store, and the
// operations that read and change it.
//
// The engine owns no buffer, no terminal and no process. It owns the
// workspace, the projects, the resource references, the presentations, the
// shared context and the record of the operations that were carried out
// (contract/workspace-model.org).
//
// The editor and the multiplexer keep their own state and ask the engine
// for the rest. The store is files in one state directory, and the state
// directory is an argument: no environment variable names it.
//
// Nothing here ticks. The engine has no listener, no thread and no timer:
// a program asks it when it wakes on an event.

pub mod model;
pub mod operations;
pub mod snapshot;
pub mod store;

use std::path::Path;

use serde_json::Value;

pub use store::Store;

/// PROTOCOL is the version of the operation envelope.
pub const PROTOCOL: &str = "workspace-operations/1";

/// STATE_PROTOCOL is the version of the state file.
pub const STATE_PROTOCOL: &str = "workspace-state/1";

/// CONTEXT_PROTOCOL is the version of the snapshot an agent reads.
pub const CONTEXT_PROTOCOL: &str = "workspace-context/1";

/// Engine is the workspace, open on its state directory.
pub struct Engine {
    store: Store,
}

impl Engine {
    /// open makes the engine ready, and answers it.
    pub fn open(state_dir: &Path) -> Result<Engine, String> {
        Ok(Engine {
            store: Store::open(state_dir)?,
        })
    }

    /// apply carries out one request and answers it in the one envelope.
    pub fn apply(&self, request: &Value) -> Value {
        operations::apply(&self.store, request)
    }

    /// snapshot answers the whole workspace as one document.
    pub fn snapshot(&self, workspace: &str) -> Result<Value, String> {
        snapshot::snapshot(&self.store, workspace)
    }

    /// store answers where the engine keeps its files.
    pub fn store(&self) -> &Store {
        &self.store
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_engine_answers_an_operation_in_the_one_envelope() {
        let dir = std::env::temp_dir().join("workspace-engine-envelope");
        let _ = std::fs::remove_dir_all(&dir);
        let engine = Engine::open(&dir).expect("the engine opens");
        let answer = engine.apply(&json!({
            "protocol": PROTOCOL,
            "request": "r1",
            "op": "workspace.create",
            "args": { "name": "the work" },
        }));
        assert_eq!(answer.get("protocol").unwrap(), PROTOCOL);
        assert_eq!(answer.get("state").unwrap(), "completed");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_snapshot_names_the_version_it_was_taken_from() {
        let dir = std::env::temp_dir().join("workspace-engine-snapshot");
        let _ = std::fs::remove_dir_all(&dir);
        let engine = Engine::open(&dir).expect("the engine opens");
        engine.apply(&json!({
            "protocol": PROTOCOL,
            "request": "r1",
            "op": "workspace.create",
            "args": { "name": "the work" },
        }));
        let document = engine.snapshot("w1").expect("the snapshot answers");
        assert_eq!(document.get("protocol").unwrap(), CONTEXT_PROTOCOL);
        assert_eq!(document.get("version").unwrap(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
