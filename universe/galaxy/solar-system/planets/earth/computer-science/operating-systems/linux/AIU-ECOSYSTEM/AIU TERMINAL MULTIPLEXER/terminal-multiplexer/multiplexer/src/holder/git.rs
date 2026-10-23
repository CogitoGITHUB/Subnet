// One job: the Git seam of the holder — the shared layer asked, and the
// model's own data given back.
//
// The holder holds the session, and the session lives in a directory: that
// is the directory Git is asked about. The layer is read-only, so asking it
// changes nothing, and the answer is the same model the editor reads, so
// the two programs cannot disagree about what Git says.

use std::path::Path;

use git_inspection::command::Comparison;
use git_inspection::model;
use git_inspection::Git;
use serde_json::{json, Value};

/// Answer is what the layer said: whether it could answer, and the data.
pub struct Answer {
    pub ok: bool,
    pub data: Value,
}

/// read asks the layer what Git says in a directory, and answers with the
/// model's own data.
///
/// The "what" says which view is asked for: the overview of the repository
/// and its worktrees, the changed files, the diff of one comparison, the
/// history, or the branches.
pub fn read(directory: &Path, what: &str) -> Answer {
    let git = match Git::open(directory) {
        Ok(git) => git,
        Err(why) => {
            return Answer {
                ok: false,
                data: json!({ "why": why }),
            }
        }
    };
    let data = match what {
        "changed" => {
            let status = git.status();
            json!({ "status": status.to_json() })
        }
        "diff" => match git.diffs(Comparison::WorkingVsIndex) {
            Ok(files) => json!({
                "comparison": Comparison::WorkingVsIndex.name(),
                "files": files
                    .iter()
                    .map(|file| json!({
                        "path": file.path,
                        "hunks": file.hunks.iter().map(|hunk| json!({
                            "old-start": hunk.old_start,
                            "old-lines": hunk.old_lines,
                            "new-start": hunk.new_start,
                            "new-lines": hunk.new_lines,
                            "lines": hunk.lines.iter().map(|line| json!({
                                "kind": line.kind.name(),
                                "mark": line.kind.mark(),
                                "text": line.text,
                                "old-line": line.old_line,
                                "new-line": line.new_line,
                            })).collect::<Vec<Value>>(),
                        })).collect::<Vec<Value>>(),
                    }))
                    .collect::<Vec<Value>>(),
            }),
            Err(why) => {
                return Answer {
                    ok: false,
                    data: json!({ "why": why }),
                }
            }
        },
        "history" => match git.log(None) {
            Ok(commits) => json!({
                "commits": commits.iter().map(|commit| commit.to_json()).collect::<Vec<Value>>(),
            }),
            Err(why) => {
                return Answer {
                    ok: false,
                    data: json!({ "why": why }),
                }
            }
        },
        "branches" => json!({
            "branches": git.branches().iter().map(|branch| json!({
                "name": branch.name,
                "head": branch.head,
                "upstream": branch.upstream,
                "divergence": branch.divergence.name(),
                "ahead": branch.divergence.ahead(),
                "behind": branch.divergence.behind(),
                "is-head": branch.is_head,
            })).collect::<Vec<Value>>(),
        }),
        _ => {
            // The overview: where the repository stands, what changed, and
            // every worktree of it.
            let status = git.status();
            let repository = git.repository();
            json!({
                "status": status.to_json(),
                "repository": match repository {
                    Ok(repository) => repository.to_json(),
                    Err(_) => json!({}),
                },
            })
        }
    };
    Answer { ok: true, data }
}

/// the_model_is_shared says the marks the layer gives are the marks the
/// multiplexer shows: there is one meaning, and it is the layer's.
#[allow(dead_code)]
fn the_model_is_shared() -> &'static str {
    model::WorkingTree::Modified.mark()
}
