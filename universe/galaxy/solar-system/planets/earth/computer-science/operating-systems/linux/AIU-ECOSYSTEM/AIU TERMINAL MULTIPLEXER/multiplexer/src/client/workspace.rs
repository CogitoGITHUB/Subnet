// One job: the workspace panel — the shared workspace as the multiplexer
// shows it.
//
// The panel is built from the data the holder answers with: the engine's
// own facts, read as the multiplexer reads them. Nothing here touches the
// engine and nothing here decides anything: the holder asked the engine,
// and this file only turns the answer into lines.

use serde_json::Value;

/// lines answers the lines of the panel for one answer of the holder.
///
/// The "view" says which view was asked for: the workspaces and their
/// projects, or the context as it stands.
pub fn lines(view: &str, data: &Value) -> Vec<String> {
    match view {
        "context" => context(data),
        _ => workspaces(data),
    }
}

/// workspaces answers the lines of the workspaces: the one this session
/// works on, its projects, and the context as it stands.
fn workspaces(data: &Value) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    let held = list(data, "workspaces");
    lines.push(format!("  the workspaces: {}", held.len()));
    for one in &held {
        let name = text(one, "name").unwrap_or_default();
        let id = text(one, "id").unwrap_or_default();
        lines.push(format!("    {}  {}", id, name));
        let projects = list(one, "projects");
        lines.push(format!("      the projects: {}", projects.len()));
        for project in &projects {
            let project_name = text(project, "name").unwrap_or_default();
            let project_id = text(project, "id").unwrap_or_default();
            let roots = strings(project, "roots");
            let mut line = format!("        {}  {}", project_id, project_name);
            if !roots.is_empty() {
                line.push_str(&format!("  {}", roots.join(", ")));
            }
            lines.push(line);
        }
        let context = one.get("context").cloned().unwrap_or(Value::Null);
        lines.push(format!("      the context: {}", the_context(&context)));
    }
    if held.is_empty() {
        lines.push("  there is no workspace yet".to_string());
    }
    lines.push(format!("  the project: {}", the_project(data)));
    lines
}

/// context answers the lines of the context as it stands: the project it
/// names and the resources it holds.
fn context(data: &Value) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    lines.push(format!("  the workspace: {}", the_workspace(data)));
    lines.push(format!("  the project: {}", the_project(data)));
    let held = list(data, "workspaces");
    for one in &held {
        let context = one.get("context").cloned().unwrap_or(Value::Null);
        lines.push(format!("  the resources: {}", strings(&context, "resources").len()));
        for resource in strings(&context, "resources") {
            lines.push(format!("    {}", resource));
        }
    }
    lines
}

/// the_workspace answers the name of the workspace this session works on.
fn the_workspace(data: &Value) -> String {
    let id = text(data, "workspace").unwrap_or_default();
    if id.is_empty() {
        return "none".to_string();
    }
    for one in list(data, "workspaces") {
        if text(&one, "id").as_deref() == Some(id.as_str()) {
            return text(&one, "name").unwrap_or(id);
        }
    }
    id
}

/// the_project answers the name of the project the context stands on.
fn the_project(data: &Value) -> String {
    let project = text(data, "project").unwrap_or_default();
    if project.is_empty() {
        return "none".to_string();
    }
    project
}

/// the_context answers the context of one workspace in a line: the project
/// it names and the resources it holds.
fn the_context(context: &Value) -> String {
    let project = text(context, "project").unwrap_or_default();
    let resources = strings(context, "resources");
    if project.is_empty() {
        return format!("no project, {} resources", resources.len());
    }
    format!("the project {}, {} resources", project, resources.len())
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
    use serde_json::json;

    #[test]
    fn the_workspaces_are_one_line_each_with_their_projects() {
        let data = json!({
            "workspaces": [{
                "id": "w1",
                "name": "the work",
                "projects": [
                    { "id": "p1", "name": "the first", "roots": ["/src"], "tags": [] },
                    { "id": "p2", "name": "the second", "roots": [], "tags": [] }
                ],
                "context": { "project": "the first", "resources": [] }
            }],
            "workspace": "w1",
            "project": "the first"
        });
        let lines = lines("list", &data);
        assert!(lines[0].contains("the workspaces: 1"), "the count: {:?}", lines);
        assert!(lines[1].contains("w1") && lines[1].contains("the work"), "the workspace: {:?}", lines);
        assert!(lines.iter().any(|line| line.contains("the projects: 2")));
        assert!(lines.iter().any(|line| line.contains("the first") && line.contains("/src")));
        assert!(lines.iter().any(|line| line.contains("the project: the first")));
    }

    #[test]
    fn an_empty_workspace_says_so() {
        let data = json!({ "workspaces": [], "workspace": "", "project": "" });
        let lines = lines("list", &data);
        assert!(lines.iter().any(|line| line.contains("there is no workspace yet")));
        assert!(lines.iter().any(|line| line.contains("the project: none")));
    }

    #[test]
    fn the_context_view_names_the_project_and_its_resources() {
        let data = json!({
            "workspaces": [{
                "id": "w1",
                "name": "the work",
                "projects": [],
                "context": { "project": "the first", "resources": ["r1", "r2"] }
            }],
            "workspace": "w1",
            "project": "the first"
        });
        let lines = lines("context", &data);
        assert!(lines.iter().any(|line| line.contains("the workspace: the work")));
        assert!(lines.iter().any(|line| line.contains("the project: the first")));
        assert!(lines.iter().any(|line| line.contains("the resources: 2")));
        assert!(lines.iter().any(|line| line.trim() == "r1"));
    }
}
