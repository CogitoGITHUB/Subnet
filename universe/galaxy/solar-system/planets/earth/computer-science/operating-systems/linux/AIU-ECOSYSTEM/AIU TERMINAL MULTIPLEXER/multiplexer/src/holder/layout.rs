// One job: the layout file — the panes a session holds, by name.
//
// The file is data and it is read once, at the start, as an argument. The
// holder reads no config file and no environment variable for it (rule 03).

use serde_json::Value;
use std::path::Path;

/// Pane is one pane of a layout: a name, the program it runs, how much of
/// the layout it wants, and the size it asks for.
pub struct Pane {
    pub name: String,
    pub tab: String,
    pub program: String,
    pub weight: u16,
    pub cols: u16,
    pub rows: u16,
}

/// Layout is what a layout file says: the direction the panes are laid out
/// in, and the panes themselves.
pub struct Layout {
    pub direction: String,
    pub panes: Vec<Pane>,
}

/// read answers the layout of the layout file. A file that is not there, or
/// that holds no pane, is an error the caller names.
pub fn read(path: &Path) -> Result<Layout, String> {
    let body = std::fs::read_to_string(path)
        .map_err(|why| format!("the layout {} cannot be read: {}", path.display(), why))?;
    let parsed: Value = serde_json::from_str(&body)
        .map_err(|why| format!("the layout {} is not JSON: {}", path.display(), why))?;
    let direction = parsed
        .get("direction")
        .and_then(|value| value.as_str())
        .unwrap_or("row")
        .to_string();
    let panes = parsed
        .get("panes")
        .and_then(|value| value.as_array())
        .ok_or_else(|| format!("the layout {} holds no panes", path.display()))?;
    let mut held: Vec<Pane> = Vec::new();
    for (at, item) in panes.iter().enumerate() {
        let name = match item.get("name").and_then(|value| value.as_str()) {
            Some(found) => found.to_string(),
            None => return Err(format!("the pane {} of the layout has no name", at)),
        };
        if held.iter().any(|pane| pane.name == name) {
            return Err(format!("the layout holds two panes named {}", name));
        }
        let program = item
            .get("program")
            .and_then(|value| value.as_str())
            .unwrap_or("/bin/sh")
            .to_string();
        let tab = item
            .get("tab")
            .and_then(|value| value.as_str())
            .unwrap_or("main")
            .to_string();
        let weight = item
            .get("weight")
            .and_then(|value| value.as_u64())
            .unwrap_or(1) as u16;
        let cols = item
            .get("cols")
            .and_then(|value| value.as_u64())
            .unwrap_or(80) as u16;
        let rows = item
            .get("rows")
            .and_then(|value| value.as_u64())
            .unwrap_or(24) as u16;
        held.push(Pane {
            name,
            tab,
            program,
            weight,
            cols,
            rows,
        });
    }
    if held.is_empty() {
        return Err(format!("the layout {} holds no panes", path.display()));
    }
    Ok(Layout {
        direction,
        panes: held,
    })
}

/// one answers the smallest layout there is: a single pane, running a shell.
pub fn one(name: &str, program: &str, cols: u16, rows: u16) -> Layout {
    Layout {
        direction: "row".to_string(),
        panes: vec![Pane {
            name: name.to_string(),
            tab: "main".to_string(),
            program: program.to_string(),
            weight: 1,
            cols,
            rows,
        }],
    }
}
