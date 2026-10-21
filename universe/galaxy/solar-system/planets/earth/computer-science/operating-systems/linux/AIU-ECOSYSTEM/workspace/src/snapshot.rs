// One job: the snapshot — the one document an agent reads to understand the
// workspace, and the slice of it an agent asks for.
//
// The snapshot holds pointers and statuses. It never holds buffer text,
// terminal history, environment variables or secrets: an agent reads the
// structure of the work, and asks the program that owns a thing for the
// thing itself.

use serde_json::{json, Value};

use crate::model;
use crate::operations::CAPABILITIES;
use crate::store::Store;

/// snapshot answers the whole workspace as one document.
pub fn snapshot(store: &Store, workspace: &str) -> Result<Value, String> {
    let state = match store.read(workspace)? {
        Some(state) => state,
        None => return Err(format!("there is no workspace {}", workspace)),
    };
    Ok(json!({
        "protocol": crate::CONTEXT_PROTOCOL,
        "taken": model::now_stamp(),
        "version": state.version,
        "workspace": state.workspace.to_json(),
        "projects": state.projects.iter().map(|project| project.to_json()).collect::<Vec<Value>>(),
        "resources": state.resources.iter().map(|resource| resource.to_json()).collect::<Vec<Value>>(),
        "presentations": state.presentations.iter().map(|presentation| presentation.to_json()).collect::<Vec<Value>>(),
        "context": state.context.to_json(),
        "applications": Value::Object(state.applications.clone()),
        "operations": state.operations.clone(),
        "capabilities": CAPABILITIES.iter().map(|name| json!(name)).collect::<Vec<Value>>(),
    }))
}

/// slice answers one part of the snapshot, so an agent asks for the part it
/// needs and not the whole environment.
pub fn slice(document: &Value, part: &str) -> Option<Value> {
    document.get(part).cloned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_snapshot_holds_no_text_and_no_environment() {
        let document = json!({
            "protocol": crate::CONTEXT_PROTOCOL,
            "workspace": { "id": "w1", "name": "the work" },
            "resources": [{ "id": "r1", "kind": "terminal", "status": "live" }],
        });
        let written = document.to_string();
        assert!(!written.contains("PATH"), "the snapshot holds the environment");
        assert!(!written.contains("pid"), "the snapshot holds a process id");
    }

    #[test]
    fn a_slice_is_one_part_of_the_document() {
        let document = json!({ "workspace": { "id": "w1" }, "projects": [] });
        assert_eq!(
            slice(&document, "workspace").expect("the part is there").get("id").unwrap(),
            "w1"
        );
        assert!(slice(&document, "nothing").is_none());
    }
}
