// One job: the workspace seam of the holder — the engine asked, and the
// facts given back.
//
// The holder holds the session; the workspace is the one thing this
// program and the editor share. The engine owns the workspaces, their
// projects and the context, and the holder only asks the engine and gives
// the facts back. The engine's own envelope is the shape of the answer:
// the state, the data and the reason.
//
// The engine never ticks and this seam never waits: a program asks when
// it wakes on an event, and the answer comes at once.

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{json, Value};
use workspace::Engine;

/// Answer is what the engine said: whether it could answer, the data it
/// gave, and the reason when it could not.
pub struct Answer {
    pub ok: bool,
    pub data: Value,
    pub reason: String,
}

/// requests counts the requests this seam made, so every one of them has
/// its own name. The engine answers a change with the same name once, and
/// never twice.
static REQUESTS: AtomicU64 = AtomicU64::new(0);

/// read asks the engine what the workspace holds, and answers with the
/// facts.
///
/// The "what" says which view is asked for: the workspaces and their
/// projects, or the context as it stands. The workspace is named when the
/// owner names one; the engine takes the only one there is when nobody
/// does.
pub fn read(state_dir: &Path, workspace: &str, what: &str) -> Answer {
    let engine = match Engine::open(state_dir) {
        Ok(engine) => engine,
        Err(why) => return refused(&why),
    };
    let listed = engine.apply(&request("workspace.list", json!({}), workspace));
    if !completed(&listed) {
        return refused(&reason(&listed));
    }
    let mut held: Vec<Value> = Vec::new();
    let mut current = String::new();
    let mut project = String::new();
    for one in list(data_of(&listed), "workspaces") {
        let id = text(&one, "id").unwrap_or_default();
        let name = text(&one, "name").unwrap_or_default();
        let chosen = if workspace.is_empty() {
            held.len() == 0
        } else {
            id == workspace || name == workspace
        };
        let projects = engine.apply(&request("project.list", json!({}), &id));
        let context = engine.apply(&request("context.read", json!({}), &id));
        let context_project = data_of(&context)
            .get("context")
            .and_then(|context| text(context, "project"))
            .unwrap_or_default();
        let projects_held = list(data_of(&projects), "projects");
        // The context names a project by its own name; the owner reads
        // names, not identifiers.
        let context_name = projects_held
            .iter()
            .find(|one| text(one, "id").as_deref() == Some(context_project.as_str()))
            .and_then(|one| text(one, "name"))
            .unwrap_or_else(|| context_project.clone());
        if chosen {
            current = id.clone();
            project = context_name.clone();
        }
        held.push(json!({
            "id": id,
            "name": name,
            "projects": projects_held
                .iter()
                .map(|project| json!({
                    "id": text(project, "id").unwrap_or_default(),
                    "name": text(project, "name").unwrap_or_default(),
                    "roots": strings(project, "roots"),
                    "tags": strings(project, "tags"),
                }))
                .collect::<Vec<Value>>(),
            "context": {
                "project": context_name,
                "project-id": context_project,
                "resources": data_of(&context)
                    .get("context")
                    .map(|context| strings(context, "resources"))
                    .unwrap_or_default(),
            },
        }));
    }
    Answer {
        ok: true,
        data: json!({
            "workspaces": held,
            "workspace": current,
            "project": project,
            "view": what,
        }),
        reason: String::new(),
    }
}

/// write asks the engine to change the workspace, and answers with the
/// facts as they stand after the change.
///
/// The "what" says which change is asked for: a workspace is created, a
/// project is registered, or the context is opened on a project. The name
/// is what the change is about.
pub fn write(state_dir: &Path, workspace: &str, what: &str, name: &str) -> Answer {
    let engine = match Engine::open(state_dir) {
        Ok(engine) => engine,
        Err(why) => return refused(&why),
    };
    let (op, args) = match what {
        "create" => ("workspace.create", json!({ "name": name })),
        "project" => ("project.register", json!({ "name": name })),
        "open" => {
            // The owner names a project; the engine knows a project by its
            // own name, so the name is resolved here.
            let target = match the_project_of(&engine, workspace, name) {
                Some(target) => target,
                None => {
                    return refused(&format!(
                        "there is no project {} in the workspace",
                        name
                    ))
                }
            };
            ("context.write", json!({ "project": target }))
        }
        other => {
            return refused(&format!(
                "{} is not a change this seam makes",
                other
            ))
        }
    };
    let answered = engine.apply(&request(op, args, workspace));
    if !completed(&answered) {
        return refused(&reason(&answered));
    }
    let mut answer = read(state_dir, workspace, "list");
    if answer.ok {
        answer.data["changed"] = json!(answered.get("data").cloned().unwrap_or(json!({})));
    }
    answer
}

/// the_project_of answers the id of the project the owner named, in the
/// workspace this session works on.
fn the_project_of(engine: &Engine, workspace: &str, name: &str) -> Option<String> {
    let listed = engine.apply(&request("workspace.list", json!({}), workspace));
    let workspaces = list(data_of(&listed), "workspaces");
    let chosen = if workspace.is_empty() {
        if workspaces.len() == 1 {
            workspaces.first()
        } else {
            None
        }
    } else {
        workspaces
            .iter()
            .find(|one| text(one, "id").as_deref() == Some(workspace) || text(one, "name").as_deref() == Some(workspace))
    }?;
    let id = text(chosen, "id")?;
    let projects = engine.apply(&request("project.list", json!({}), &id));
    for one in list(data_of(&projects), "projects") {
        if text(&one, "id").as_deref() == Some(name) || text(&one, "name").as_deref() == Some(name) {
            return text(&one, "id");
        }
    }
    None
}

/// data_of answers the data of the engine's answer.
fn data_of(answer: &Value) -> &Value {
    answer.get("data").unwrap_or(&Value::Null)
}

/// request builds the engine's own request: the protocol, the name of
/// this request, the operation and its arguments.
fn request(op: &str, args: Value, workspace: &str) -> Value {
    let number = REQUESTS.fetch_add(1, Ordering::Relaxed);
    let mut request = json!({
        "protocol": workspace::PROTOCOL,
        "request": format!("multiplexer-{}", number),
        "op": op,
        "args": args,
    });
    if !workspace.is_empty() {
        request["workspace"] = json!(workspace);
    }
    request
}

/// completed answers whether the engine's answer says the work was done.
fn completed(answer: &Value) -> bool {
    answer.get("state").and_then(|state| state.as_str()) == Some("completed")
}

/// reason answers why the engine refused, in its own words.
fn reason(answer: &Value) -> String {
    answer
        .get("reason")
        .and_then(|reason| reason.as_str())
        .unwrap_or("the engine did not say why")
        .to_string()
}

/// refused answers a seam that could not ask: the reason, and no data.
fn refused(why: &str) -> Answer {
    Answer {
        ok: false,
        data: json!({ "why": why }),
        reason: why.to_string(),
    }
}

/// text answers one string field of a value.
fn text(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(|part| part.as_str())
        .map(|found| found.to_string())
}

/// strings answers the list of strings under a key of a value.
fn strings(value: &Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(|part| part.as_array())
        .map(|found| {
            found
                .iter()
                .filter_map(|part| part.as_str())
                .map(|part| part.to_string())
                .collect()
        })
        .unwrap_or_default()
}

/// list answers the list under a key of a value.
fn list(value: &Value, key: &str) -> Vec<Value> {
    value
        .get(key)
        .and_then(|part| part.as_array())
        .cloned()
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// a_directory answers a directory of its own for the tests.
    fn a_directory(name: &str) -> std::path::PathBuf {
        let directory = std::env::temp_dir().join(name);
        let _ = std::fs::remove_dir_all(&directory);
        directory
    }

    #[test]
    fn an_empty_workspace_directory_holds_no_workspace() {
        let directory = a_directory("mux-workspace-empty");
        let answer = read(&directory, "", "list");
        assert!(answer.ok, "the engine answers: {}", answer.reason);
        assert_eq!(
            answer.data.get("workspaces").and_then(|held| held.as_array()).map(|held| held.len()),
            Some(0),
            "there is no workspace yet: {:?}",
            answer.data
        );
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_workspace_and_its_project_are_held_after_the_change() {
        let directory = a_directory("mux-workspace-made");
        let created = write(&directory, "", "create", "the work");
        assert!(created.ok, "the workspace is made: {}", created.reason);
        let registered = write(&directory, "", "project", "the first");
        assert!(registered.ok, "the project is registered: {}", registered.reason);
        let held = read(&directory, "", "list");
        assert!(held.ok, "the workspace is read: {}", held.reason);
        let workspaces = list(&held.data, "workspaces");
        assert_eq!(workspaces.len(), 1, "one workspace: {:?}", held.data);
        let name = text(&workspaces[0], "name").unwrap_or_default();
        assert_eq!(name, "the work", "the workspace is named: {:?}", workspaces[0]);
        let projects = list(&workspaces[0], "projects");
        assert_eq!(projects.len(), 1, "one project: {:?}", workspaces[0]);
        let project = text(&projects[0], "name").unwrap_or_default();
        assert_eq!(project, "the first", "the project is named: {:?}", projects[0]);
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn opening_a_project_puts_it_in_the_context() {
        let directory = a_directory("mux-workspace-context");
        assert!(write(&directory, "", "create", "the work").ok);
        assert!(write(&directory, "", "project", "the first").ok);
        let opened = write(&directory, "", "open", "the first");
        assert!(opened.ok, "the context is opened: {}", opened.reason);
        let held = read(&directory, "", "list");
        let project = text(&held.data, "project").unwrap_or_default();
        assert_eq!(project, "the first", "the context names it: {:?}", held.data);
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_project_that_is_not_there_is_refused_by_name() {
        let directory = a_directory("mux-workspace-refused");
        assert!(write(&directory, "", "create", "the work").ok);
        let opened = write(&directory, "", "open", "not here");
        assert!(!opened.ok, "the engine refuses: {:?}", opened.data);
        assert!(
            opened.reason.contains("not here"),
            "the refusal names it: {}",
            opened.reason
        );
        let _ = std::fs::remove_dir_all(&directory);
    }
}
