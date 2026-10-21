// One job: the workspace model — the workspace, the project, the resource
// reference, the presentation, the context and the state that holds them,
// and how each one is written as JSON.
//
// A resource reference names a thing one of the programs owns. It never
// holds the thing itself: no buffer text, no terminal output, no process
// id. Its status says what is known about the thing, and it is never a
// guess.

use serde_json::{json, Map, Value};

/// text answers one string field of a JSON object, or an empty string.
pub fn text(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(|part| part.as_str())
        .unwrap_or("")
        .to_string()
}

/// list answers one list-of-strings field of a JSON object.
pub fn list(value: &Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(|part| part.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(|word| word.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

/// map answers one free-form object field of a JSON object.
pub fn map(value: &Value, key: &str) -> Map<String, Value> {
    value
        .get(key)
        .and_then(|part| part.as_object())
        .cloned()
        .unwrap_or_default()
}

/// now_stamp answers the wall clock as a record keeps it: the UTC time, to
/// the second. It reads the clock and never waits for one.
pub fn now_stamp() -> String {
    let seconds = match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(moment) => moment.as_secs() as i64,
        Err(_) => 0,
    };
    let days = seconds.div_euclid(86_400);
    let rest = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year,
        month,
        day,
        rest / 3600,
        (rest % 3600) / 60,
        rest % 60
    )
}

/// civil_from_days answers the calendar date of a count of days since the
/// epoch. It is the standard shift: the epoch moves to 0000-03-01, the
/// count is turned into a year and a day of the year, and the month is
/// found afterwards.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let shifted = days + 719_468;
    let era = if shifted >= 0 { shifted } else { shifted - 146_096 } / 146_097;
    let day_of_era = shifted - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let day = (day_of_year - (153 * shifted_month + 2) / 5 + 1) as u32;
    let month = if shifted_month < 10 {
        shifted_month + 3
    } else {
        shifted_month - 9
    } as u32;
    let year = if month <= 2 { year + 1 } else { year };
    (year, month, day)
}

/// Workspace is the top boundary: it holds projects, and through them it
/// points at the resources the programs own.
#[derive(Debug)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    pub created: String,
    pub modified: String,
}

impl Workspace {
    /// to_json answers the workspace as it is written.
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "name": self.name,
            "created": self.created,
            "modified": self.modified,
        })
    }

    /// from_json reads a workspace, and refuses a shape that is not one.
    pub fn from_json(value: &Value) -> Result<Workspace, String> {
        let id = text(value, "id");
        if id.is_empty() {
            return Err("a workspace without an identifier".to_string());
        }
        Ok(Workspace {
            id,
            name: text(value, "name"),
            created: text(value, "created"),
            modified: text(value, "modified"),
        })
    }
}

/// Project is a unit of work, not a folder: it may name several roots,
/// documents, workflows and terminals.
#[derive(Debug)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub roots: Vec<String>,
    pub tags: Vec<String>,
    pub commands: Vec<String>,
    pub docs: Vec<String>,
    pub settings: Map<String, Value>,
}

impl Project {
    /// to_json answers the project as it is written.
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "name": self.name,
            "roots": self.roots,
            "tags": self.tags,
            "commands": self.commands,
            "docs": self.docs,
            "settings": Value::Object(self.settings.clone()),
        })
    }

    /// from_json reads a project, and refuses a shape that is not one.
    pub fn from_json(value: &Value) -> Result<Project, String> {
        let id = text(value, "id");
        if id.is_empty() {
            return Err("a project without an identifier".to_string());
        }
        Ok(Project {
            id,
            name: text(value, "name"),
            roots: list(value, "roots"),
            tags: list(value, "tags"),
            commands: list(value, "commands"),
            docs: list(value, "docs"),
            settings: map(value, "settings"),
        })
    }
}

/// ResourceRef is one pointer to a thing a program owns.
#[derive(Debug)]
pub struct ResourceRef {
    pub id: String,
    pub kind: String,
    pub owner: String,
    pub project: String,
    pub label: String,
    pub location: String,
    pub status: String,
    pub capabilities: Vec<String>,
    pub related: Vec<String>,
}

impl ResourceRef {
    /// to_json answers the reference as it is written.
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "kind": self.kind,
            "owner": self.owner,
            "project": self.project,
            "label": self.label,
            "location": self.location,
            "status": self.status,
            "capabilities": self.capabilities,
            "related": self.related,
        })
    }

    /// from_json reads a reference, and refuses a shape that is not one.
    pub fn from_json(value: &Value) -> Result<ResourceRef, String> {
        let id = text(value, "id");
        if id.is_empty() {
            return Err("a resource without an identifier".to_string());
        }
        Ok(ResourceRef {
            id,
            kind: text(value, "kind"),
            owner: text(value, "owner"),
            project: text(value, "project"),
            label: text(value, "label"),
            location: text(value, "location"),
            status: text(value, "status"),
            capabilities: list(value, "capabilities"),
            related: list(value, "related"),
        })
    }
}

/// Presentation is a saved arrangement of resource references. It names what
/// it shows; it does not own what it shows.
#[derive(Debug)]
pub struct Presentation {
    pub id: String,
    pub name: String,
    pub resources: Vec<String>,
}

impl Presentation {
    /// to_json answers the presentation as it is written.
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "name": self.name,
            "resources": self.resources,
        })
    }

    /// from_json reads a presentation, and refuses a shape that is not one.
    pub fn from_json(value: &Value) -> Result<Presentation, String> {
        let id = text(value, "id");
        if id.is_empty() {
            return Err("a presentation without an identifier".to_string());
        }
        Ok(Presentation {
            id,
            name: text(value, "name"),
            resources: list(value, "resources"),
        })
    }
}

/// Context is what is being worked on now: the project, the resources in
/// hand, and what the owner said about them.
#[derive(Debug)]
pub struct Context {
    pub project: String,
    pub resources: Vec<String>,
    pub notes: Map<String, Value>,
}

impl Context {
    /// to_json answers the context as it is written.
    pub fn to_json(&self) -> Value {
        json!({
            "project": self.project,
            "resources": self.resources,
            "notes": Value::Object(self.notes.clone()),
        })
    }

    /// from_json reads a context, and refuses a shape that is not one.
    pub fn from_json(value: &Value) -> Result<Context, String> {
        Ok(Context {
            project: text(value, "project"),
            resources: list(value, "resources"),
            notes: map(value, "notes"),
        })
    }
}

/// State is everything one workspace holds, and the version of it.
#[derive(Debug)]
pub struct State {
    pub version: u64,
    pub workspace: Workspace,
    pub projects: Vec<Project>,
    pub resources: Vec<ResourceRef>,
    pub presentations: Vec<Presentation>,
    pub context: Context,
    pub applications: Map<String, Value>,
    pub operations: Vec<Value>,
}

impl State {
    /// to_json answers the whole state as it is written.
    pub fn to_json(&self) -> Value {
        json!({
            "protocol": crate::STATE_PROTOCOL,
            "version": self.version,
            "workspace": self.workspace.to_json(),
            "projects": self.projects.iter().map(|project| project.to_json()).collect::<Vec<Value>>(),
            "resources": self.resources.iter().map(|resource| resource.to_json()).collect::<Vec<Value>>(),
            "presentations": self.presentations.iter().map(|presentation| presentation.to_json()).collect::<Vec<Value>>(),
            "context": self.context.to_json(),
            "applications": Value::Object(self.applications.clone()),
            "operations": self.operations.clone(),
        })
    }

    /// from_json reads the whole state, and refuses a shape that is not one.
    pub fn from_json(value: &Value) -> Result<State, String> {
        let protocol = text(value, "protocol");
        if protocol != crate::STATE_PROTOCOL {
            return Err(format!(
                "the workspace state speaks {} and this engine speaks {}",
                protocol,
                crate::STATE_PROTOCOL
            ));
        }
        let workspace = match value.get("workspace") {
            Some(part) => Workspace::from_json(part)?,
            None => return Err("the workspace state has no workspace".to_string()),
        };
        let projects = read_list(value, "projects", |part| Project::from_json(part))?;
        let resources = read_list(value, "resources", |part| ResourceRef::from_json(part))?;
        let presentations = read_list(value, "presentations", |part| Presentation::from_json(part))?;
        let context = match value.get("context") {
            Some(part) => Context::from_json(part)?,
            None => Context {
                project: String::new(),
                resources: Vec::new(),
                notes: Map::new(),
            },
        };
        Ok(State {
            version: value
                .get("version")
                .and_then(|part| part.as_u64())
                .unwrap_or(0),
            workspace,
            projects,
            resources,
            presentations,
            context,
            applications: map(value, "applications"),
            operations: value
                .get("operations")
                .and_then(|part| part.as_array())
                .cloned()
                .unwrap_or_default(),
        })
    }

    /// project answers one project by its identifier.
    pub fn project(&self, id: &str) -> Option<&Project> {
        self.projects.iter().find(|project| project.id == id)
    }

    /// resource answers one resource by its identifier.
    pub fn resource(&self, id: &str) -> Option<&ResourceRef> {
        self.resources.iter().find(|resource| resource.id == id)
    }

    /// presentation answers one presentation by its identifier.
    pub fn presentation(&self, id: &str) -> Option<&Presentation> {
        self.presentations
            .iter()
            .find(|presentation| presentation.id == id)
    }
}

/// read_list reads one list of records from a JSON object, and refuses a
/// shape that is not one.
fn read_list<T, F>(value: &Value, key: &str, read: F) -> Result<Vec<T>, String>
where
    F: Fn(&Value) -> Result<T, String>,
{
    let items = match value.get(key) {
        Some(part) => part
            .as_array()
            .ok_or_else(|| format!("the {} field is not a list", key))?,
        None => return Ok(Vec::new()),
    };
    let mut out: Vec<T> = Vec::new();
    for item in items {
        out.push(read(item)?);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_stamp_is_a_utc_time_to_the_second() {
        let stamp = now_stamp();
        assert_eq!(stamp.len(), 20, "the stamp is not a time: {}", stamp);
        assert!(stamp.ends_with('Z'), "the stamp is not UTC: {}", stamp);
    }

    #[test]
    fn the_epoch_day_is_the_first_of_march_in_the_year_zero() {
        // 1970-01-01 is day zero, and the shift counts from 0000-03-01.
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(19_000), (2022, 1, 8));
        assert_eq!(civil_from_days(-1), (1969, 12, 31));
    }

    #[test]
    fn a_resource_holds_a_pointer_and_never_the_thing() {
        let reference = ResourceRef::from_json(&json!({
            "id": "r1",
            "kind": "terminal",
            "owner": "multiplexer",
            "project": "p1",
            "label": "build",
            "location": "",
            "status": "live",
        }))
        .expect("the reference reads");
        assert_eq!(reference.id, "r1");
        assert_eq!(reference.owner, "multiplexer");
        assert_eq!(reference.status, "live");
        // The written form holds no text and no process id.
        let written = reference.to_json().to_string();
        assert!(!written.contains("pid"), "the reference holds a process id");
    }

    #[test]
    fn a_state_that_speaks_another_version_is_refused() {
        let wrong = json!({ "protocol": "workspace-state/99" });
        let why = State::from_json(&wrong).expect_err("the wrong version is refused");
        assert!(why.contains("workspace-state/99"), "the refusal names it: {}", why);
    }
}
