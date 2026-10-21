// One job: the Git facts the hot path answers with — the shared layer
// asked, and the facts given back.
//
// The facts are the shared layer's own model, and they cross the seam as
// the seam's shape asks: names and values, all strings. The editor's
// status line and its gutter need facts, not a document, and the
// multiplexer shows the same facts in its panel.
//
// The layer only reads. Nothing here can change a repository, an index,
// a branch or a worktree, and the editor's buffer is never saved to find
// out what Git says.

use std::path::{Path, PathBuf};

use git_inspection::Git;

/// facts answers the Git facts of a file: the repository it is in, the
/// branch, the distance from the upstream, the counts, the file's own
/// state in the index and in the working tree, and how fresh it all is.
///
/// A path that is not inside a repository is refused by name, and the
/// facts say so instead of pretending the tree is clean.
pub fn facts(file: &Path) -> Vec<(String, String)> {
    // The path is made whole first: the status names its files as the
    // repository names them, and a path with a ".." in it is not that.
    let file = std::fs::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
    let file = file.as_path();
    let directory = match file.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.to_path_buf(),
        _ => PathBuf::from("."),
    };
    let git = match Git::open(&directory) {
        Ok(git) => git,
        Err(why) => {
            return vec![
                ("git-state".to_string(), "unknown".to_string()),
                ("git-why".to_string(), why),
            ]
        }
    };
    let status = git.status();
    let mut out: Vec<(String, String)> = Vec::new();
    out.push(("git-repository".to_string(), git.root().display().to_string()));
    out.push(("git-branch".to_string(), status.head.name()));
    out.push(("git-divergence".to_string(), status.divergence.name().to_string()));
    if let Some(ahead) = status.divergence.ahead() {
        out.push(("git-ahead".to_string(), ahead.to_string()));
    }
    if let Some(behind) = status.divergence.behind() {
        out.push(("git-behind".to_string(), behind.to_string()));
    }
    out.push(("git-staged".to_string(), status.counts.staged.to_string()));
    out.push(("git-unstaged".to_string(), status.counts.unstaged.to_string()));
    out.push(("git-untracked".to_string(), status.counts.untracked.to_string()));
    out.push(("git-conflicts".to_string(), status.counts.conflicted.to_string()));
    out.push(("git-freshness".to_string(), status.freshness.name().to_string()));
    // The file's own state: what the index holds of it, and what the
    // working tree holds of it. The two are apart.
    let wanted = relative_to(git.root(), file);
    match status
        .files
        .iter()
        .find(|entry| entry.path == wanted)
    {
        Some(entry) => {
            out.push(("git-file".to_string(), entry.path.clone()));
            out.push(("git-file-index".to_string(), entry.index.name().to_string()));
            out.push(("git-file-working".to_string(), entry.working.name().to_string()));
        }
        None => {
            out.push(("git-file".to_string(), wanted));
            out.push(("git-file-index".to_string(), "unchanged".to_string()));
            out.push(("git-file-working".to_string(), "clean".to_string()));
        }
    }
    out
}

/// relative_to answers a path as the repository names it: the paths of
/// the status are relative to the root of the repository.
fn relative_to(root: &Path, file: &Path) -> String {
    let root = std::fs::canonicalize(root)
        .unwrap_or_else(|_| root.to_path_buf())
        .display()
        .to_string();
    let file = file.display().to_string();
    match file.strip_prefix(&root) {
        Some(rest) => rest.trim_start_matches('/').to_string(),
        None => file,
    }
}
