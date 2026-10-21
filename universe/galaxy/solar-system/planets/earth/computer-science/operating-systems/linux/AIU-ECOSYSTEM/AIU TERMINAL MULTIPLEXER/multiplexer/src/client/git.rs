// One job: the Git panel — the shared model as the multiplexer shows it.
//
// The panel is built from the data the holder answers with: the shared
// layer's own model, read as the multiplexer reads it. The marks are the
// layer's marks, so the two programs say the same thing about the same
// repository.
//
// Nothing here runs Git and nothing here decides anything: the holder
// asked the layer, and this file only turns the answer into lines.

use serde_json::Value;

/// lines answers the lines of the panel for one answer of the holder.
///
/// The "what" says which view was asked for: the overview of the
/// repository and its worktrees, the changed files, the diff of one
/// comparison, the history, or the branches.
pub fn lines(want: &str, data: &Value) -> Vec<String> {
    match want {
        "changed" => changed(data),
        "diff" => diff(data),
        "history" => history(data),
        "branches" => branches(data),
        _ => overview(data),
    }
}

/// overview answers the lines of the whole repository: where it stands,
/// what changed, and every worktree of it.
fn overview(data: &Value) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    let status = data.get("status").cloned().unwrap_or(Value::Null);
    let repository = data.get("repository").cloned().unwrap_or(Value::Null);
    if let Some(root) = text(&repository, "root") {
        lines.push(format!("  the repository: {}", root));
    }
    let head = text(&status, "head").unwrap_or_default();
    let upstream = text(&status, "upstream");
    let mut branch_line = format!("  the branch: {}", head);
    if let Some(upstream) = upstream {
        branch_line.push_str(&format!("  of {}", upstream));
    }
    let ahead = number(&status, "ahead");
    let behind = number(&status, "behind");
    match (ahead, behind) {
        (Some(ahead), Some(behind)) => {
            branch_line.push_str(&format!("  ahead {}, behind {}", ahead, behind))
        }
        (Some(ahead), None) => branch_line.push_str(&format!("  ahead {}", ahead)),
        (None, Some(behind)) => branch_line.push_str(&format!("  behind {}", behind)),
        (None, None) => {}
    }
    lines.push(branch_line);
    lines.push(format!(
        "  the changes: {}",
        counts(&status)
    ));
    if let Some(fresh) = text(&status, "freshness") {
        lines.push(format!("  the state: {}", fresh));
    }
    let worktrees = list(&repository, "worktrees");
    lines.push(format!("  the worktrees: {}", worktrees.len()));
    for worktree in worktrees {
        let path = text(&worktree, "path").unwrap_or_default();
        let head = text(&worktree, "head").unwrap_or_default();
        lines.push(format!(
            "    {:<40} {:<20} {}",
            path,
            head,
            counts(&worktree)
        ));
    }
    lines
}

/// changed answers the lines of the changed files: the counts, then one
/// line per file with the marks the layer gives.
fn changed(data: &Value) -> Vec<String> {
    let status = data.get("status").cloned().unwrap_or(Value::Null);
    let mut lines: Vec<String> = Vec::new();
    lines.push(format!("  {}", counts(&status)));
    for file in list(&status, "files") {
        let path = text(&file, "path").unwrap_or_default();
        let staged = text(&file, "index-mark").unwrap_or_default();
        let unstaged = text(&file, "working-mark").unwrap_or_default();
        let working = text(&file, "working").unwrap_or_default();
        let index = text(&file, "index").unwrap_or_default();
        lines.push(format!(
            "  {}{} {:<40} {}",
            staged, unstaged, path, what_the_file_is(&index, &working)
        ));
    }
    lines
}

/// what_the_file_is answers the words for one file: what the index holds
/// of it, and what the working tree holds of it.
fn what_the_file_is(index: &str, working: &str) -> String {
    if working == "untracked" {
        return "untracked".to_string();
    }
    if index == "unchanged" {
        return format!("unstaged: {}", working);
    }
    if working == "clean" {
        return format!("staged: {}", index);
    }
    format!("staged: {}, unstaged: {}", index, working)
}

/// diff answers the lines of the diff: which comparison, then the files
/// and the hunks and the lines that changed.
fn diff(data: &Value) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    if let Some(comparison) = text(data, "comparison") {
        lines.push(format!("  the comparison: {}", comparison));
    }
    for file in list(data, "files") {
        let path = text(&file, "path").unwrap_or_default();
        lines.push(format!("  {}", path));
        for hunk in list(&file, "hunks") {
            let old_start = number(&hunk, "old-start").unwrap_or(0);
            let old_lines = number(&hunk, "old-lines").unwrap_or(0);
            let new_start = number(&hunk, "new-start").unwrap_or(0);
            let new_lines = number(&hunk, "new-lines").unwrap_or(0);
            lines.push(format!(
                "    @@ -{},{} +{},{} @@",
                old_start, old_lines, new_start, new_lines
            ));
            for line in list(&hunk, "lines") {
                let mark = text(&line, "mark").unwrap_or_default();
                let body = text(&line, "text").unwrap_or_default();
                lines.push(format!("    {}{}", mark, body));
            }
        }
    }
    if lines.len() <= 1 {
        lines.push("  nothing differs".to_string());
    }
    lines
}

/// history answers the lines of the history: the commits, newest first.
fn history(data: &Value) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for commit in list(data, "commits") {
        let short = text(&commit, "short").unwrap_or_default();
        let summary = text(&commit, "summary").unwrap_or_default();
        let author = text(&commit, "author").unwrap_or_default();
        let date = text(&commit, "date").unwrap_or_default();
        lines.push(format!("  {}  {}", short, summary));
        lines.push(format!("       {}  {}", author, date));
        for file in list(&commit, "files") {
            lines.push(format!("       {}", file));
        }
    }
    if lines.is_empty() {
        lines.push("  the history is empty".to_string());
    }
    lines
}

/// branches answers the lines of the branches: the name, the upstream
/// and the distance, and a star on the one the head is on.
fn branches(data: &Value) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for branch in list(data, "branches") {
        let name = text(&branch, "name").unwrap_or_default();
        let upstream = text(&branch, "upstream").unwrap_or_default();
        let divergence = text(&branch, "divergence").unwrap_or_default();
        let head = branch
            .get("is-head")
            .and_then(|value| value.as_bool())
            .unwrap_or(false);
        let mut line = format!("  {} {:<20} {:<24} {}", if head { "*" } else { " " }, name, upstream, divergence);
        if let Some(ahead) = number(&branch, "ahead") {
            line.push_str(&format!("  ahead {}", ahead));
        }
        if let Some(behind) = number(&branch, "behind") {
            line.push_str(&format!("  behind {}", behind));
        }
        lines.push(line);
    }
    if lines.is_empty() {
        lines.push("  there are no branches".to_string());
    }
    lines
}

/// counts answers the counts of a status or of a worktree, in the words
/// the layer uses.
fn counts(status: &Value) -> String {
    let counts = status.get("counts").cloned().unwrap_or(Value::Null);
    let staged = number(&counts, "staged").unwrap_or(0);
    let unstaged = number(&counts, "unstaged").unwrap_or(0);
    let untracked = number(&counts, "untracked").unwrap_or(0);
    let conflicted = number(&counts, "conflicted").unwrap_or(0);
    format!(
        "{} staged, {} unstaged, {} untracked, {} conflicts",
        staged, unstaged, untracked, conflicted
    )
}

/// text answers one string field of an answer.
fn text(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(|part| part.as_str())
        .map(|found| found.to_string())
}

/// number answers one number field of an answer.
fn number(value: &Value, key: &str) -> Option<u64> {
    value.get(key).and_then(|part| part.as_u64())
}

/// list answers the list under a key of an answer.
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
    fn a_changed_file_shows_the_two_marks_apart() {
        let data = json!({
            "status": {
                "counts": { "staged": 1, "unstaged": 1, "untracked": 0, "conflicted": 0 },
                "files": [
                    { "path": "a.txt", "index": "modified", "index-mark": "~",
                      "working": "modified", "working-mark": "~" },
                    { "path": "b.txt", "index": "unchanged", "index-mark": " ",
                      "working": "untracked", "working-mark": "?" }
                ]
            }
        });
        let lines = lines("changed", &data);
        assert!(lines[0].contains("1 staged"), "the counts are there: {:?}", lines);
        assert!(lines[1].contains("~~ a.txt"), "the marks are together: {:?}", lines);
        assert!(lines[1].contains("staged: modified"), "the words say it: {:?}", lines);
        assert!(lines[2].contains(" ? b.txt"), "the untracked mark is there: {:?}", lines);
    }

    #[test]
    fn an_unknown_upstream_is_not_shown_as_in_step() {
        let data = json!({
            "status": { "head": "main", "counts": {}, "files": [] },
            "repository": { "root": "/repo", "worktrees": [] }
        });
        let lines = lines("overview", &data);
        assert!(lines.iter().any(|line| line.contains("the branch: main")));
        assert!(
            !lines.iter().any(|line| line.contains("in step")),
            "nothing claims to be in step: {:?}",
            lines
        );
    }

    #[test]
    fn the_worktrees_are_one_line_each() {
        let data = json!({
            "status": { "head": "main", "counts": {}, "files": [] },
            "repository": {
                "root": "/repo",
                "worktrees": [
                    { "path": "/repo", "head": "main",
                      "counts": { "staged": 1, "unstaged": 0, "untracked": 0, "conflicted": 0 } },
                    { "path": "/repo/linked", "head": "side",
                      "counts": { "staged": 0, "unstaged": 2, "untracked": 0, "conflicted": 0 } }
                ]
            }
        });
        let lines = lines("overview", &data);
        assert!(lines.iter().any(|line| line.contains("/repo/linked") && line.contains("side")));
    }

    #[test]
    fn a_diff_says_which_comparison_it_is() {
        let data = json!({
            "comparison": "working tree against index",
            "files": [{
                "path": "a.txt",
                "hunks": [{
                    "old-start": 1, "old-lines": 1, "new-start": 1, "new-lines": 1,
                    "lines": [{ "kind": "added", "mark": "+", "text": "new" }]
                }]
            }]
        });
        let lines = lines("diff", &data);
        assert!(lines[0].contains("working tree against index"));
        assert!(lines.iter().any(|line| line.contains("+new")));
    }
}
