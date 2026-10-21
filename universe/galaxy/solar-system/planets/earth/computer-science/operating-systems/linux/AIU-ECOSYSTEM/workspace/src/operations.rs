// One job: the operations — the one envelope, the catalogue of what may be
// asked for, and the dispatch that answers each request with its state.
//
// A request that is understood and refused is "rejected", and the refusal
// names its reason. A request that was understood and could not be done is
// "failed". Delivery is never completion: only "completed" says that the
// thing was done.

use serde_json::{json, Value};

use crate::model::{self, Context, Presentation, Project, ResourceRef, State, Workspace};
use crate::snapshot;
use crate::store::Store;

/// CAPABILITIES are the operations this engine answers. The snapshot and
/// the explorer read this one list.
pub const CAPABILITIES: [&str; 22] = [
    "workspace.list",
    "workspace.create",
    "workspace.read",
    "workspace.rename",
    "workspace.delete",
    "workspace.validate",
    "project.register",
    "project.list",
    "project.read",
    "project.rename",
    "project.remove",
    "resource.register",
    "resource.update",
    "resource.unregister",
    "resource.list",
    "context.read",
    "context.write",
    "presentation.create",
    "presentation.list",
    "presentation.delete",
    "application.report",
    "snapshot",
];

/// MUTATING are the operations that change the workspace. A request that
/// repeats one of these with the same identifier is answered from the
/// record and never done twice.
pub const MUTATING: [&str; 13] = [
    "workspace.create",
    "workspace.rename",
    "workspace.delete",
    "project.register",
    "project.rename",
    "project.remove",
    "resource.register",
    "resource.update",
    "resource.unregister",
    "context.write",
    "presentation.create",
    "presentation.delete",
    "application.report",
];

/// Problem is a request that could not be carried out.
pub struct Problem {
    pub state: String,
    pub reason: String,
}

impl Problem {
    /// rejected is a request the engine will not do, and says why.
    fn rejected(reason: impl Into<String>) -> Problem {
        Problem {
            state: "rejected".to_string(),
            reason: reason.into(),
        }
    }

    /// failed is a request the engine understood and could not do.
    fn failed(reason: impl Into<String>) -> Problem {
        Problem {
            state: "failed".to_string(),
            reason: reason.into(),
        }
    }
}

/// apply carries out one request and answers it.
pub fn apply(store: &Store, request: &Value) -> Value {
    let op = model::text(request, "op");
    let request_id = model::text(request, "request");
    match carry_out(store, request, &op) {
        Ok(data) => answer(&request_id, &op, "completed", data, String::new()),
        Err(problem) => answer(&request_id, &op, &problem.state, json!({}), problem.reason),
    }
}

/// answer builds the one envelope every request is answered in.
fn answer(request: &str, op: &str, state: &str, data: Value, reason: String) -> Value {
    json!({
        "protocol": crate::PROTOCOL,
        "request": request,
        "op": op,
        "state": state,
        "data": data,
        "reason": reason,
    })
}

/// carry_out reads the request and does what it says.
fn carry_out(store: &Store, request: &Value, op: &str) -> Result<Value, Problem> {
    let args = request.get("args").cloned().unwrap_or(json!({}));
    // A request that repeats a change with the same identifier is answered
    // from the record: the change is done once, never twice.
    let request_id = model::text(request, "request");
    if MUTATING.contains(&op) {
        if let Some(found) = earlier(store, &request_id, op) {
            return answer_from_record(found);
        }
    }
    match op {
        "workspace.list" => {
            let ids = store
                .workspace_ids()
                .map_err(|why| Problem::failed(why))?;
            let mut workspaces: Vec<Value> = Vec::new();
            for id in ids {
                if let Some(state) = store
                    .read(&id)
                    .map_err(|why| Problem::failed(why))?
                {
                    workspaces.push(json!({
                        "id": state.workspace.id,
                        "name": state.workspace.name,
                        "version": state.version,
                        "modified": state.workspace.modified,
                    }));
                }
            }
            Ok(json!({ "workspaces": workspaces }))
        }
        "workspace.create" => {
            let name = model::text(&args, "name");
            if name.is_empty() {
                return Err(Problem::rejected("a workspace needs a name"));
            }
            let ids = store
                .workspace_ids()
                .map_err(|why| Problem::failed(why))?;
            let id = next_id("w", &ids);
            let stamp = model::now_stamp();
            let mut state = State {
                version: 1,
                workspace: Workspace {
                    id: id.clone(),
                    name: name.clone(),
                    created: stamp.clone(),
                    modified: stamp,
                },
                projects: Vec::new(),
                resources: Vec::new(),
                presentations: Vec::new(),
                context: Context {
                    project: String::new(),
                    resources: Vec::new(),
                    notes: serde_json::Map::new(),
                },
                applications: serde_json::Map::new(),
                operations: Vec::new(),
            };
            let data = json!({ "workspace": state.workspace.to_json() });
            record(
                &mut state,
                &model::text(request, "request"),
                op,
                "completed",
                &data,
                &String::new(),
            );
            store
                .write(&id, &state)
                .map_err(|why| Problem::failed(why))?;
            Ok(data)
        }
        "workspace.read" => {
            let workspace = workspace_of(store, request)?;
            let state = load(store, &workspace)?;
            Ok(json!({
                "workspace": state.workspace.to_json(),
                "version": state.version,
                "projects": state.projects.len(),
                "resources": state.resources.len(),
                "presentations": state.presentations.len(),
            }))
        }
        "workspace.rename" => {
            let workspace = workspace_of(store, request)?;
            let name = model::text(&args, "name");
            if name.is_empty() {
                return Err(Problem::rejected("a workspace needs a name"));
            }
            mutate(store, request, &workspace, |state| {
                state.workspace.name = name.clone();
                Ok(json!({ "workspace": state.workspace.to_json() }))
            })
        }
        "workspace.delete" => {
            let workspace = workspace_of(store, request)?;
            store
                .remove(&workspace)
                .map_err(|why| Problem::failed(why))?;
            Ok(json!({
                "workspace": workspace,
                "closed": "nothing else: no terminal was closed and no file was deleted",
            }))
        }
        "workspace.validate" => {
            let workspace = workspace_of(store, request)?;
            let state = load(store, &workspace)?;
            let mut problems: Vec<String> = Vec::new();
            for resource in &state.resources {
                if !resource.project.is_empty() && state.project(&resource.project).is_none() {
                    problems.push(format!(
                        "the resource {} names the project {}, and there is no such project",
                        resource.id, resource.project
                    ));
                }
            }
            for presentation in &state.presentations {
                for resource in &presentation.resources {
                    if state.resource(resource).is_none() {
                        problems.push(format!(
                            "the presentation {} names the resource {}, and there is no such resource",
                            presentation.id, resource
                        ));
                    }
                }
            }
            if !state.context.project.is_empty()
                && state.project(&state.context.project).is_none()
            {
                problems.push(format!(
                    "the context names the project {}, and there is no such project",
                    state.context.project
                ));
            }
            Ok(json!({
                "workspace": workspace,
                "ok": problems.is_empty(),
                "problems": problems,
            }))
        }
        "project.register" => {
            let workspace = workspace_of(store, request)?;
            let name = model::text(&args, "name");
            if name.is_empty() {
                return Err(Problem::rejected("a project needs a name"));
            }
            mutate(store, request, &workspace, |state| {
                let ids: Vec<String> = state.projects.iter().map(|p| p.id.clone()).collect();
                let project = Project {
                    id: next_id("p", &ids),
                    name: name.clone(),
                    roots: model::list(&args, "roots"),
                    tags: model::list(&args, "tags"),
                    commands: model::list(&args, "commands"),
                    docs: model::list(&args, "docs"),
                    settings: model::map(&args, "settings"),
                };
                let written = project.to_json();
                state.projects.push(project);
                Ok(json!({ "project": written }))
            })
        }
        "project.list" => {
            let workspace = workspace_of(store, request)?;
            let state = load(store, &workspace)?;
            let projects: Vec<Value> = state.projects.iter().map(|p| p.to_json()).collect();
            Ok(json!({ "projects": projects }))
        }
        "project.read" => {
            let workspace = workspace_of(store, request)?;
            let state = load(store, &workspace)?;
            let wanted = model::text(&args, "project");
            match state.project(&wanted) {
                Some(project) => Ok(json!({ "project": project.to_json() })),
                None => Err(Problem::rejected(format!(
                    "there is no project {} in the workspace {}",
                    wanted, workspace
                ))),
            }
        }
        "project.rename" => {
            let workspace = workspace_of(store, request)?;
            let wanted = model::text(&args, "project");
            let name = model::text(&args, "name");
            if name.is_empty() {
                return Err(Problem::rejected("a project needs a name"));
            }
            mutate(store, request, &workspace, |state| match state.projects.iter_mut().find(|p| p.id == wanted) {
                Some(project) => {
                    project.name = name.clone();
                    Ok(json!({ "project": project.to_json() }))
                }
                None => Err(Problem::rejected(format!(
                    "there is no project {} in the workspace {}",
                    wanted, workspace
                ))),
            })
        }
        "project.remove" => {
            let workspace = workspace_of(store, request)?;
            let wanted = model::text(&args, "project");
            mutate(store, request, &workspace, |state| {
                if state.projects.iter().all(|p| p.id != wanted) {
                    return Err(Problem::rejected(format!(
                        "there is no project {} in the workspace {}",
                        wanted, workspace
                    )));
                }
                state.projects.retain(|p| p.id != wanted);
                // The references of that project are forgotten with it. The
                // program that owns them keeps them: nothing is closed.
                let forgotten = state.resources.len();
                state.resources.retain(|r| r.project != wanted);
                let kept = forgotten - state.resources.len();
                if state.context.project == wanted {
                    state.context.project = String::new();
                }
                let living: Vec<String> = state
                    .context
                    .resources
                    .iter()
                    .filter(|one| state.resource(one).is_some())
                    .cloned()
                    .collect();
                state.context.resources = living;
                Ok(json!({
                    "project": wanted,
                    "references_forgotten": kept,
                    "closed": "nothing else: no terminal was closed and no buffer was deleted",
                }))
            })
        }
        "resource.register" => {
            let workspace = workspace_of(store, request)?;
            let kind = model::text(&args, "kind");
            let owner = model::text(&args, "owner");
            if kind.is_empty() {
                return Err(Problem::rejected("a resource needs a kind"));
            }
            if owner != "editor" && owner != "multiplexer" {
                return Err(Problem::rejected(
                    "a resource is owned by the editor or by the multiplexer",
                ));
            }
            mutate(store, request, &workspace, |state| {
                let project = model::text(&args, "project");
                if !project.is_empty() && state.project(&project).is_none() {
                    return Err(Problem::rejected(format!(
                        "there is no project {} in the workspace {}",
                        project, workspace
                    )));
                }
                let ids: Vec<String> = state.resources.iter().map(|r| r.id.clone()).collect();
                let resource = ResourceRef {
                    id: next_id("r", &ids),
                    kind: kind.clone(),
                    owner: owner.clone(),
                    project: project.clone(),
                    label: model::text(&args, "label"),
                    location: model::text(&args, "location"),
                    status: "live".to_string(),
                    capabilities: model::list(&args, "capabilities"),
                    related: Vec::new(),
                };
                let written = resource.to_json();
                state.resources.push(resource);
                Ok(json!({ "resource": written }))
            })
        }
        "resource.update" => {
            let workspace = workspace_of(store, request)?;
            let wanted = model::text(&args, "resource");
            mutate(store, request, &workspace, |state| {
                let resource = match state.resources.iter_mut().find(|r| r.id == wanted) {
                    Some(resource) => resource,
                    None => {
                        return Err(Problem::rejected(format!(
                            "there is no resource {} in the workspace {}",
                            wanted, workspace
                        )))
                    }
                };
                let status = model::text(&args, "status");
                if !status.is_empty() {
                    if status != "live" && status != "stale" && status != "gone" {
                        return Err(Problem::rejected(
                            "a resource is live, stale or gone: nothing else is a status",
                        ));
                    }
                    resource.status = status.clone();
                }
                let label = model::text(&args, "label");
                if !label.is_empty() {
                    resource.label = label.clone();
                }
                let location = model::text(&args, "location");
                if !location.is_empty() {
                    resource.location = location.clone();
                }
                let capabilities = model::list(&args, "capabilities");
                if !capabilities.is_empty() {
                    resource.capabilities = capabilities.clone();
                }
                Ok(json!({ "resource": resource.to_json() }))
            })
        }
        "resource.unregister" => {
            let workspace = workspace_of(store, request)?;
            let wanted = model::text(&args, "resource");
            mutate(store, request, &workspace, |state| {
                if state.resources.iter().all(|r| r.id != wanted) {
                    return Err(Problem::rejected(format!(
                        "there is no resource {} in the workspace {}",
                        wanted, workspace
                    )));
                }
                state.resources.retain(|r| r.id != wanted);
                state.context.resources.retain(|r| r != &wanted);
                for presentation in state.presentations.iter_mut() {
                    presentation.resources.retain(|r| r != &wanted);
                }
                Ok(json!({
                    "resource": wanted,
                    "closed": "nothing else: the pointer is gone and the thing it named is not touched",
                }))
            })
        }
        "resource.list" => {
            let workspace = workspace_of(store, request)?;
            let state = load(store, &workspace)?;
            let project = model::text(&args, "project");
            let kind = model::text(&args, "kind");
            let owner = model::text(&args, "owner");
            let status = model::text(&args, "status");
            let tag = model::text(&args, "tag");
            let mut resources: Vec<Value> = Vec::new();
            for resource in &state.resources {
                if !project.is_empty() && resource.project != project {
                    continue;
                }
                if !kind.is_empty() && resource.kind != kind {
                    continue;
                }
                if !owner.is_empty() && resource.owner != owner {
                    continue;
                }
                if !status.is_empty() && resource.status != status {
                    continue;
                }
                if !tag.is_empty() {
                    let tagged = state
                        .project(&resource.project)
                        .map(|project| project.tags.iter().any(|one| one == &tag))
                        .unwrap_or(false);
                    if !tagged {
                        continue;
                    }
                }
                resources.push(resource.to_json());
            }
            Ok(json!({ "resources": resources }))
        }
        "context.read" => {
            let workspace = workspace_of(store, request)?;
            let state = load(store, &workspace)?;
            Ok(json!({ "context": state.context.to_json() }))
        }
        "context.write" => {
            let workspace = workspace_of(store, request)?;
            mutate(store, request, &workspace, |state| {
                let project = model::text(&args, "project");
                if !project.is_empty() && state.project(&project).is_none() {
                    return Err(Problem::rejected(format!(
                        "there is no project {} in the workspace {}",
                        project, workspace
                    )));
                }
                let resources = model::list(&args, "resources");
                for resource in &resources {
                    if state.resource(resource).is_none() {
                        return Err(Problem::rejected(format!(
                            "there is no resource {} in the workspace {}",
                            resource, workspace
                        )));
                    }
                }
                state.context.project = project.clone();
                state.context.resources = resources.clone();
                let notes = model::map(&args, "notes");
                if !notes.is_empty() {
                    state.context.notes = notes.clone();
                }
                Ok(json!({ "context": state.context.to_json() }))
            })
        }
        "presentation.create" => {
            let workspace = workspace_of(store, request)?;
            let name = model::text(&args, "name");
            if name.is_empty() {
                return Err(Problem::rejected("a presentation needs a name"));
            }
            mutate(store, request, &workspace, |state| {
                let resources = model::list(&args, "resources");
                for resource in &resources {
                    if state.resource(resource).is_none() {
                        return Err(Problem::rejected(format!(
                            "there is no resource {} in the workspace {}",
                            resource, workspace
                        )));
                    }
                }
                let ids: Vec<String> = state.presentations.iter().map(|p| p.id.clone()).collect();
                let presentation = Presentation {
                    id: next_id("s", &ids),
                    name: name.clone(),
                    resources: resources.clone(),
                };
                let written = presentation.to_json();
                state.presentations.push(presentation);
                Ok(json!({ "presentation": written }))
            })
        }
        "presentation.list" => {
            let workspace = workspace_of(store, request)?;
            let state = load(store, &workspace)?;
            let presentations: Vec<Value> =
                state.presentations.iter().map(|p| p.to_json()).collect();
            Ok(json!({ "presentations": presentations }))
        }
        "presentation.delete" => {
            let workspace = workspace_of(store, request)?;
            let wanted = model::text(&args, "presentation");
            mutate(store, request, &workspace, |state| {
                if state.presentations.iter().all(|p| p.id != wanted) {
                    return Err(Problem::rejected(format!(
                        "there is no presentation {} in the workspace {}",
                        wanted, workspace
                    )));
                }
                state.presentations.retain(|p| p.id != wanted);
                Ok(json!({
                    "presentation": wanted,
                    "closed": "nothing else: the arrangement is gone and the resources it showed are not touched",
                }))
            })
        }
        "application.report" => {
            let workspace = workspace_of(store, request)?;
            let application = model::text(&args, "application");
            if application != "editor" && application != "multiplexer" {
                return Err(Problem::rejected(
                    "a report comes from the editor or from the multiplexer",
                ));
            }
            mutate(store, request, &workspace, |state| {
                let report = json!({
                    "running": args.get("running").and_then(|v| v.as_bool()).unwrap_or(false),
                    "resources": model::list(&args, "resources"),
                    "reported": model::now_stamp(),
                });
                state
                    .applications
                    .insert(application.clone(), report.clone());
                Ok(json!({ "application": application, "report": report }))
            })
        }
        "snapshot" => {
            let workspace = workspace_of(store, request)?;
            snapshot::snapshot(store, &workspace).map_err(|why| Problem::failed(why))
        }
        other => Err(Problem::rejected(format!(
            "{} is not an operation this engine answers",
            other
        ))),
    }
}

/// workspace_of answers the workspace a request is about: the one it names,
/// or the only one there is.
fn workspace_of(store: &Store, request: &Value) -> Result<String, Problem> {
    let named = model::text(request, "workspace");
    if !named.is_empty() {
        return Ok(named);
    }
    let ids = store
        .workspace_ids()
        .map_err(|why| Problem::failed(why))?;
    match ids.len() {
        1 => Ok(ids[0].clone()),
        0 => Err(Problem::rejected("there is no workspace yet: create one first")),
        _ => Err(Problem::rejected(
            "there are several workspaces: name the one the request is about",
        )),
    }
}

/// load reads the state of one workspace.
fn load(store: &Store, workspace: &str) -> Result<State, Problem> {
    match store
        .read(workspace)
        .map_err(|why| Problem::failed(why))?
    {
        Some(state) => Ok(state),
        None => Err(Problem::rejected(format!(
            "there is no workspace {}",
            workspace
        ))),
    }
}

/// mutate loads the state, does the work, and puts the state back with the
/// version moved on and the operation written down.
fn mutate(
    store: &Store,
    request: &Value,
    workspace: &str,
    body: impl FnOnce(&mut State) -> Result<Value, Problem>,
) -> Result<Value, Problem> {
    let mut state = load(store, workspace)?;
    if let Some(expect) = request.get("expect").and_then(|part| part.as_u64()) {
        if expect != state.version {
            return Err(Problem::rejected(format!(
                "the workspace {} moved on: it is at version {}, and the request expected {}",
                workspace, state.version, expect
            )));
        }
    }
    let request_id = model::text(request, "request");
    let op = model::text(request, "op");
    match body(&mut state) {
        Ok(data) => {
            state.version += 1;
            state.workspace.modified = model::now_stamp();
            record(&mut state, &request_id, &op, "completed", &data, &String::new());
            store
                .write(workspace, &state)
                .map_err(|why| Problem::failed(why))?;
            Ok(data)
        }
        Err(problem) => {
            record(
                &mut state,
                &request_id,
                &op,
                &problem.state,
                &json!({}),
                &problem.reason,
            );
            let _ = store.write(workspace, &state);
            Err(problem)
        }
    }
}

/// record writes one operation down, and keeps the last fifty.
fn record(state: &mut State, request: &str, op: &str, outcome: &str, data: &Value, reason: &str) {
    state.operations.push(json!({
        "request": request,
        "op": op,
        "state": outcome,
        "data": data.clone(),
        "reason": reason,
        "when": model::now_stamp(),
    }));
    if state.operations.len() > 50 {
        let extra = state.operations.len() - 50;
        state.operations.drain(0..extra);
    }
}

/// earlier answers the record of a request that was carried out before, in
/// any workspace of the store.
fn earlier(store: &Store, request_id: &str, op: &str) -> Option<Value> {
    if request_id.is_empty() {
        return None;
    }
    for id in store.workspace_ids().ok()? {
        if let Ok(Some(state)) = store.read(&id) {
            // The same identifier with another operation is another
            // request: only a repeat of the same operation is a repeat.
            let found = state.operations.iter().find(|one| {
                one.get("request").and_then(|part| part.as_str()) == Some(request_id)
                    && one.get("op").and_then(|part| part.as_str()) == Some(op)
            });
            if let Some(found) = found {
                return Some(found.clone());
            }
        }
    }
    None
}

/// answer_from_record answers a repeated request from the record, and does
/// the work again never.
fn answer_from_record(record: Value) -> Result<Value, Problem> {
    let outcome = model::text(&record, "state");
    if outcome == "completed" {
        return Ok(record.get("data").cloned().unwrap_or(json!({})));
    }
    Err(Problem {
        state: if outcome.is_empty() {
            "rejected".to_string()
        } else {
            outcome
        },
        reason: model::text(&record, "reason"),
    })
}

/// next_id answers the first free identifier of a kind: p1, p2, and so on.
fn next_id(prefix: &str, taken: &[String]) -> String {
    let mut at = taken.len() + 1;
    loop {
        let candidate = format!("{}{}", prefix, at);
        if !taken.iter().any(|id| id == &candidate) {
            return candidate;
        }
        at += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn store(name: &str) -> Store {
        let dir: PathBuf = std::env::temp_dir().join(format!("workspace-ops-{}", name));
        let _ = fs::remove_dir_all(&dir);
        Store::open(&dir).expect("the store opens")
    }

    fn request(op: &str, args: Value) -> Value {
        json!({ "protocol": crate::PROTOCOL, "request": "r1", "op": op, "args": args })
    }

    fn completed(answer: &Value) -> bool {
        answer.get("state").and_then(|part| part.as_str()) == Some("completed")
    }

    #[test]
    fn an_operation_that_is_not_known_is_refused_by_name() {
        let store = store("unknown");
        let answer = apply(&store, &request("workspace.fly", json!({})));
        assert_eq!(answer.get("state").unwrap(), "rejected");
        assert!(answer.get("reason").unwrap().as_str().unwrap().contains("workspace.fly"));
    }

    #[test]
    fn a_workspace_is_created_and_read_back() {
        let store = store("create");
        let created = apply(&store, &request("workspace.create", json!({ "name": "the work" })));
        assert!(completed(&created));
        let listed = apply(&store, &request("workspace.list", json!({})));
        let workspaces = listed.get("data").unwrap().get("workspaces").unwrap().as_array().unwrap();
        assert_eq!(workspaces.len(), 1);
        assert_eq!(workspaces[0].get("name").unwrap(), "the work");
    }

    #[test]
    fn a_project_and_a_resource_survive_the_store_being_opened_again() {
        let dir = std::env::temp_dir().join("workspace-ops-survive");
        let _ = fs::remove_dir_all(&dir);
        let store = Store::open(&dir).expect("the store opens");
        let created = apply(&store, &request("workspace.create", json!({ "name": "the work" })));
        let workspace = created
            .get("data")
            .unwrap()
            .get("workspace")
            .unwrap()
            .get("id")
            .unwrap()
            .as_str()
            .unwrap()
            .to_string();
        let project = apply(
            &store,
            &request(
                "project.register",
                json!({ "name": "the multiplexer", "roots": ["AIU TERMINAL MULTIPLEXER"] }),
            ),
        );
        assert!(completed(&project));
        let project_id = project
            .get("data")
            .unwrap()
            .get("project")
            .unwrap()
            .get("id")
            .unwrap()
            .as_str()
            .unwrap()
            .to_string();
        let resource = apply(
            &store,
            &request(
                "resource.register",
                json!({ "kind": "terminal", "owner": "multiplexer", "project": project_id, "label": "build" }),
            ),
        );
        assert!(completed(&resource));

        // A new store on the same directory is what a restart looks like.
        let again = Store::open(&dir).expect("the store opens again");
        let listed = apply(
            &again,
            &request("resource.list", json!({ "workspace": workspace })),
        );
        let resources = listed
            .get("data")
            .unwrap()
            .get("resources")
            .unwrap()
            .as_array()
            .unwrap();
        assert_eq!(resources.len(), 1);
        assert_eq!(resources[0].get("label").unwrap(), "build");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_resource_of_a_project_that_is_not_there_is_refused() {
        let store = store("orphan");
        apply(&store, &request("workspace.create", json!({ "name": "the work" })));
        let answer = apply(
            &store,
            &request(
                "resource.register",
                json!({ "kind": "terminal", "owner": "multiplexer", "project": "p9" }),
            ),
        );
        assert_eq!(answer.get("state").unwrap(), "rejected");
        assert!(answer.get("reason").unwrap().as_str().unwrap().contains("p9"));
    }

    #[test]
    fn removing_a_project_forgets_its_references_and_closes_nothing() {
        let store = store("remove");
        apply(&store, &request("workspace.create", json!({ "name": "the work" })));
        apply(&store, &request("project.register", json!({ "name": "p" })));
        apply(
            &store,
            &request(
                "resource.register",
                json!({ "kind": "terminal", "owner": "multiplexer", "project": "p1" }),
            ),
        );
        let answer = apply(&store, &request("project.remove", json!({ "project": "p1" })));
        assert!(completed(&answer));
        let data = answer.get("data").unwrap();
        assert_eq!(data.get("references_forgotten").unwrap(), 1);
        assert!(data.get("closed").unwrap().as_str().unwrap().contains("no terminal was closed"));
        let resources = apply(&store, &request("resource.list", json!({})));
        assert!(resources.get("data").unwrap().get("resources").unwrap().as_array().unwrap().is_empty());
    }

    #[test]
    fn a_request_that_expected_an_old_version_is_refused() {
        let store = store("expect");
        apply(&store, &request("workspace.create", json!({ "name": "the work" })));
        let answer = apply(
            &store,
            &json!({
                "protocol": crate::PROTOCOL,
                "request": "r2",
                "op": "project.register",
                "args": { "name": "late" },
                "expect": 0,
            }),
        );
        assert_eq!(answer.get("state").unwrap(), "rejected");
        assert!(answer.get("reason").unwrap().as_str().unwrap().contains("moved on"));
    }

    #[test]
    fn the_operations_are_written_down() {
        let store = store("record");
        apply(&store, &request("workspace.create", json!({ "name": "the work" })));
        let snapshot = apply(&store, &request("snapshot", json!({})));
        let operations = snapshot
            .get("data")
            .unwrap()
            .get("operations")
            .unwrap()
            .as_array()
            .unwrap();
        assert!(!operations.is_empty(), "the operations are written down");
    }

    #[test]
    fn a_repeated_change_is_answered_from_the_record_and_is_not_done_twice() {
        let store = store("duplicate");
        apply(&store, &request("workspace.create", json!({ "name": "the work" })));
        let once = apply(
            &store,
            &json!({
                "protocol": crate::PROTOCOL,
                "request": "p1",
                "op": "project.register",
                "args": { "name": "once" },
            }),
        );
        assert!(completed(&once));
        let again = apply(
            &store,
            &json!({
                "protocol": crate::PROTOCOL,
                "request": "p1",
                "op": "project.register",
                "args": { "name": "once" },
            }),
        );
        assert!(completed(&again));
        assert_eq!(
            once.get("data"),
            again.get("data"),
            "the repeated request is answered from the record"
        );
        let listed = apply(&store, &request("project.list", json!({})));
        let projects = listed
            .get("data")
            .unwrap()
            .get("projects")
            .unwrap()
            .as_array()
            .unwrap();
        assert_eq!(projects.len(), 1, "the change was done once");
    }
}
