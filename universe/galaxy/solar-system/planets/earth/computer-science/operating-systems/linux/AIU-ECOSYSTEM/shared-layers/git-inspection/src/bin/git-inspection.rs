// One job: the one-shot program — one request in a file, one answer in a
// file.
//
// The editor's join seam carries the two languages over files, because a
// child given a pipe is mute in that Racket build. This program speaks the
// same way: it reads a request file and writes an answer file, and it never
// waits on a stream.
//
// The answers are the model's own data: the same states the multiplexer
// reads, so the two programs cannot disagree about what Git says.

use std::path::{Path, PathBuf};

use git_inspection::{command::Comparison, model, Git};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => {}
        Err(why) => {
            eprintln!("{}", why);
            std::process::exit(2);
        }
    }
}

/// run reads the request, asks the layer, and writes the answer.
fn run(args: &[String]) -> Result<(), String> {
    let mut request: Option<PathBuf> = None;
    let mut response: Option<PathBuf> = None;
    let mut at = 0;
    while at < args.len() {
        match args[at].as_str() {
            "--request" => {
                at += 1;
                request = Some(PathBuf::from(
                    args.get(at).ok_or("--request needs a file")?,
                ));
            }
            "--response" => {
                at += 1;
                response = Some(PathBuf::from(
                    args.get(at).ok_or("--response needs a file")?,
                ));
            }
            "--help" => {
                println!(
                    "git-inspection --request FILE --response FILE\n\n\
                     One request in, one answer out. The request names the\n\
                     operation and the path; the answer is the model's own\n\
                     data, the same states the multiplexer reads."
                );
                return Ok(());
            }
            other => return Err(format!("{} is not an option this program knows", other)),
        }
        at += 1;
    }
    let request = request.ok_or("the program needs --request")?;
    let response = response.ok_or("the program needs --response")?;
    let text = std::fs::read_to_string(&request)
        .map_err(|why| format!("the request file {} cannot be read: {}", request.display(), why))?;
    let value: serde_json::Value = serde_json::from_str(&text).map_err(|why| {
        format!(
            "the request file {} does not hold a request: {}",
            request.display(),
            why
        )
    })?;
    let answer = answer_for(&value);
    std::fs::write(&response, answer.to_string()).map_err(|why| {
        format!(
            "the answer file {} cannot be written: {}",
            response.display(),
            why
        )
    })
}

/// answer_for carries out one request and answers it in one shape.
fn answer_for(request: &serde_json::Value) -> serde_json::Value {
    let op = request
        .get("op")
        .and_then(|part| part.as_str())
        .unwrap_or("")
        .to_string();
    let path = request
        .get("path")
        .and_then(|part| part.as_str())
        .unwrap_or(".")
        .to_string();
    let mut answer = serde_json::json!({
        "protocol": "git-inspection/1",
        "op": op,
        "ok": true,
        "data": serde_json::json!({}),
        "refusal": serde_json::json!({}),
    });
    let git = match Git::open(Path::new(&path)) {
        Ok(git) => git,
        Err(why) => {
            answer["ok"] = serde_json::json!(false);
            answer["refusal"] = serde_json::json!({ "message": why });
            return answer;
        }
    };
    let data = match op.as_str() {
        "status" => git.status().to_json(),
        "branches" => serde_json::json!({
            "branches": git.branches().iter().map(|branch| serde_json::json!({
                "name": branch.name,
                "head": branch.head,
                "upstream": branch.upstream,
                "divergence": branch.divergence.name(),
                "ahead": branch.divergence.ahead(),
                "behind": branch.divergence.behind(),
                "is-head": branch.is_head,
            })).collect::<Vec<serde_json::Value>>()
        }),
        "repository" => git.repository().map(|repository| repository.to_json()).unwrap_or(
            serde_json::json!({}),
        ),
        "worktrees" => serde_json::json!({
            "worktrees": git.worktrees().iter().map(|worktree| worktree.to_json()).collect::<Vec<serde_json::Value>>()
        }),
        "diff" => {
            let comparison = match request
                .get("comparison")
                .and_then(|part| part.as_str())
                .unwrap_or("working-index")
            {
                "index-head" => Comparison::IndexVsHead,
                "working-head" => Comparison::WorkingVsHead,
                _ => Comparison::WorkingVsIndex,
            };
            let file = request.get("file").and_then(|part| part.as_str());
            match git.diff(file, comparison) {
                Ok(hunks) => serde_json::json!({
                    "comparison": comparison.name(),
                    "hunks": hunks.iter().map(|hunk| serde_json::json!({
                        "old-start": hunk.old_start,
                        "old-lines": hunk.old_lines,
                        "new-start": hunk.new_start,
                        "new-lines": hunk.new_lines,
                        "lines": hunk.lines.iter().map(|line| serde_json::json!({
                            "kind": line.kind.name(),
                            "mark": line.kind.mark(),
                            "text": line.text,
                            "old-line": line.old_line,
                            "new-line": line.new_line,
                        })).collect::<Vec<serde_json::Value>>()
                    })).collect::<Vec<serde_json::Value>>()
                }),
                Err(why) => {
                    answer["ok"] = serde_json::json!(false);
                    answer["refusal"] = serde_json::json!({ "message": why });
                    serde_json::json!({})
                }
            }
        }
        "log" => match git.log(request.get("file").and_then(|part| part.as_str())) {
            Ok(commits) => serde_json::json!({
                "commits": commits.iter().map(|commit| commit.to_json()).collect::<Vec<serde_json::Value>>()
            }),
            Err(why) => {
                answer["ok"] = serde_json::json!(false);
                answer["refusal"] = serde_json::json!({ "message": why });
                serde_json::json!({})
            }
        },
        "show" => {
            let object = request
                .get("commit")
                .and_then(|part| part.as_str())
                .unwrap_or("HEAD");
            match git.show(object) {
                Ok(commits) => serde_json::json!({
                    "commits": commits.iter().map(|commit| commit.to_json()).collect::<Vec<serde_json::Value>>()
                }),
                Err(why) => {
                    answer["ok"] = serde_json::json!(false);
                    answer["refusal"] = serde_json::json!({ "message": why });
                    serde_json::json!({})
                }
            }
        }
        "file-at" => {
            let object = request
                .get("object")
                .and_then(|part| part.as_str())
                .unwrap_or("HEAD");
            match git.file_at(object) {
                Ok(text) => serde_json::json!({ "text": text }),
                Err(why) => {
                    answer["ok"] = serde_json::json!(false);
                    answer["refusal"] = serde_json::json!({ "message": why });
                    serde_json::json!({})
                }
            }
        }
        other => {
            answer["ok"] = serde_json::json!(false);
            answer["refusal"] = serde_json::json!({
                "message": format!("{} is not an operation this program answers", other)
            });
            serde_json::json!({})
        }
    };
    answer["data"] = data;
    answer
}

/// The model is used here so the answer keeps the same names the layer
/// gives: a reader of the answer and a reader of the model say the same
/// thing.
#[allow(dead_code)]
fn names_are_shared() -> &'static str {
    model::WorkingTree::Modified.name()
}
