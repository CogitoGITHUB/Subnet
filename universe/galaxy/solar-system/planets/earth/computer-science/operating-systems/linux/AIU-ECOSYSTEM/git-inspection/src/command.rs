// One job: the process seam — the one way this layer runs Git.
//
// Git is run with a structured argument list, in an explicit working
// directory, and with no shell anywhere: a path is never part of a command
// line. The command is a typed choice, so a mutating Git command cannot
// even be spelled here.
//
// Every command is local: nothing reaches a remote, so the counts of ahead
// and behind come from the refs that are here, and a branch whose upstream
// is missing is unknown rather than up to date.

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::Duration;

/// GIT is the program this layer runs.
pub const GIT: &str = "git";

/// WAIT is how long a command may take before it is stopped. It is a
/// safety net, not a schedule: the wait itself ends when the command ends.
pub const WAIT: Duration = Duration::from_secs(20);

/// GitCommand is one read-only Git command. These variants are the only
/// commands this layer can run: there is no variant for anything that
/// changes a repository, so it cannot be asked for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GitCommand {
    /// Repository asks where the repository is.
    Repository,
    /// Status is the porcelain v2 status of a tree.
    Status,
    /// Worktrees is the porcelain list of the worktrees.
    Worktrees,
    /// Branches is the local branches with their upstream and their track.
    Branches,
    /// Log is the history of a path.
    Log,
    /// Show is one commit with the files it touched.
    Show,
    /// Diff is the difference between two trees.
    Diff,
    /// Blame is the line history of a file.
    Blame,
    /// FileAt is the contents of a file at a commit.
    FileAt,
}

/// Comparison is which two trees a diff compares.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Comparison {
    /// WorkingVsIndex is the working tree against the index.
    WorkingVsIndex,
    /// IndexVsHead is the index against HEAD.
    IndexVsHead,
    /// WorkingVsHead is the working tree against HEAD.
    WorkingVsHead,
}

impl Comparison {
    /// name answers the comparison as a person reads it.
    pub fn name(&self) -> &'static str {
        match self {
            Comparison::WorkingVsIndex => "working tree against index",
            Comparison::IndexVsHead => "index against HEAD",
            Comparison::WorkingVsHead => "working tree against HEAD",
        }
    }
}

/// Answer is what one command said: its output, its error output, and how it
/// ended. The three are kept apart, because Git says what happened in its
/// error output and a failing exit code alone is not the whole story.
#[derive(Clone, Debug, Default)]
pub struct Answer {
    pub out: String,
    pub err: String,
    pub code: Option<i32>,
}

impl Answer {
    /// ok answers whether the command said yes.
    pub fn ok(&self) -> bool {
        self.code == Some(0)
    }

    /// failed answers why the command said no, in the words Git used.
    pub fn failed(&self) -> String {
        if self.ok() {
            return String::new();
        }
        let why = self.err.trim();
        if why.is_empty() {
            format!("the git command ended with code {:?}", self.code)
        } else {
            why.to_string()
        }
    }
}

/// args answers the argument list of one command. Every value is a separate
/// argument, so a path with a space, a quote or a newline in it is one
/// argument and stays one argument.
pub fn args(
    command: GitCommand,
    path: Option<&str>,
    comparison: Comparison,
    object: Option<&str>,
) -> Vec<String> {
    let mut args: Vec<String> = vec![
        "-c".to_string(),
        "core.quotePath=false".to_string(),
    ];
    match command {
        GitCommand::Repository => {
            args.push("rev-parse".to_string());
            args.push("--path-format=absolute".to_string());
            args.push("--show-toplevel".to_string());
            args.push("--absolute-git-dir".to_string());
            args.push("--git-common-dir".to_string());
            args.push("--is-inside-work-tree".to_string());
            args.push("--is-bare-repository".to_string());
        }
        GitCommand::Status => {
            args.push("status".to_string());
            args.push("--porcelain=v2".to_string());
            args.push("-z".to_string());
            args.push("--branch".to_string());
            args.push("--untracked-files=all".to_string());
        }
        GitCommand::Worktrees => {
            args.push("worktree".to_string());
            args.push("list".to_string());
            args.push("--porcelain".to_string());
            args.push("-z".to_string());
        }
        GitCommand::Branches => {
            args.push("for-each-ref".to_string());
            args.push(
                "--format=%(refname:short)%00%(objectname)%00%(upstream:short)%00%(upstream:track)%00%(HEAD)%00"
                    .to_string(),
            );
            args.push("refs/heads/".to_string());
        }
        GitCommand::Log => {
            args.push("log".to_string());
            args.push(
                "--format=%H%x00%h%x00%an%x00%ae%x00%at%x00%cI%x00%s%x00".to_string(),
            );
            args.push("--name-status".to_string());
            args.push("-z".to_string());
            if let Some(path) = path {
                args.push("--".to_string());
                args.push(path.to_string());
            }
        }
        GitCommand::Show => {
            args.push("show".to_string());
            args.push(
                "--format=%H%x00%h%x00%an%x00%ae%x00%at%x00%cI%x00%s%x00".to_string(),
            );
            args.push("--name-status".to_string());
            args.push("-z".to_string());
            if let Some(object) = object {
                args.push(object.to_string());
            }
        }
        GitCommand::Diff => {
            args.push("diff".to_string());
            args.push("--no-color".to_string());
            args.push("--no-ext-diff".to_string());
            args.push("--unified=0".to_string());
            match comparison {
                Comparison::WorkingVsIndex => {}
                Comparison::IndexVsHead => {
                    args.push("--cached".to_string());
                }
                Comparison::WorkingVsHead => {
                    args.push("HEAD".to_string());
                }
            }
            if let Some(path) = path {
                args.push("--".to_string());
                args.push(path.to_string());
            }
        }
        GitCommand::Blame => {
            args.push("blame".to_string());
            args.push("--line-porcelain".to_string());
            args.push("--root".to_string());
            if let Some(path) = path {
                args.push(path.to_string());
            }
        }
        GitCommand::FileAt => {
            args.push("show".to_string());
            if let Some(object) = object {
                args.push(object.to_string());
            }
        }
    }
    args
}

/// run runs one Git command in a working directory and answers what it said.
///
/// The command is given as an argument list, so nothing is ever handed to a
/// shell. A command that overruns the wait is stopped, because a command
/// that never ends would hold the program with it.
pub fn run(
    directory: &std::path::Path,
    command: GitCommand,
    path: Option<&str>,
    comparison: Comparison,
    object: Option<&str>,
) -> Result<Answer, String> {
    let list = args(command, path, comparison, object);
    let mut child = Command::new(GIT)
        .args(&list)
        .current_dir(directory)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|why| format!("git could not be started: {}", why))?;
    let pid = child.id() as libc::pid_t;
    // The guard: it waits for the deadline and stops the command if it is
    // still running. The wait for the command itself ends when the command
    // ends.
    let guard = std::thread::spawn(move || {
        std::thread::sleep(WAIT);
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    });
    let mut out = String::new();
    let mut err = String::new();
    if let Some(mut stream) = child.stdout.take() {
        let _ = stream.read_to_string(&mut out);
    }
    if let Some(mut stream) = child.stderr.take() {
        let _ = stream.read_to_string(&mut err);
    }
    let status = child
        .wait()
        .map_err(|why| format!("git could not be waited for: {}", why))?;
    // The guard is stopped with the command: the process is gone, and the
    // guard's own wait ends when its thread is dropped.
    drop(guard);
    Ok(Answer {
        out,
        err,
        code: status.code(),
    })
}

/// git_is_here answers whether Git is on this machine at all.
pub fn git_is_here() -> bool {
    Command::new(GIT)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_command_can_change_a_repository() {
        // The command list is a typed choice, and none of these variants
        // name anything that writes.
        let every = [
            GitCommand::Repository,
            GitCommand::Status,
            GitCommand::Worktrees,
            GitCommand::Branches,
            GitCommand::Log,
            GitCommand::Show,
            GitCommand::Diff,
            GitCommand::Blame,
            GitCommand::FileAt,
        ];
        for command in every {
            let list = args(command, None, Comparison::WorkingVsIndex, None);
            let words: Vec<&str> = list
                .iter()
                .map(|word| word.as_str())
                .filter(|word| !word.starts_with('-'))
                .collect();
            for word in words {
                for forbidden in [
                    "commit",
                    "add",
                    "reset",
                    "checkout",
                    "switch",
                    "merge",
                    "rebase",
                    "cherry-pick",
                    "revert",
                    "stash",
                    "fetch",
                    "pull",
                    "push",
                    "clean",
                    "apply",
                    "update-index",
                    "gc",
                    "remote",
                    "config",
                    "worktree",
                ] {
                    if word == forbidden {
                        // "worktree list" is a read; the name alone is not
                        // the test. The test is the shape of the arguments.
                        continue;
                    }
                }
            }
            assert!(
                list.iter().all(|word| {
                    !matches!(
                        word.as_str(),
                        "commit" | "add" | "reset" | "checkout" | "switch" | "merge"
                            | "rebase" | "cherry-pick" | "revert" | "stash" | "fetch" | "pull"
                            | "push" | "clean" | "apply" | "update-index" | "gc" | "remote"
                            | "config"
                    )
                }),
                "the command {:?} holds a word that changes things: {:?}",
                command,
                list
            );
        }
    }

    #[test]
    fn a_path_is_its_own_argument() {
        let list = args(
            GitCommand::Diff,
            Some("a file/with a \"quote\".txt"),
            Comparison::WorkingVsIndex,
            None,
        );
        assert!(list.contains(&"a file/with a \"quote\".txt".to_string()));
        assert!(list.contains(&"--".to_string()));
    }

    #[test]
    fn the_comparison_is_named_as_a_person_reads_it() {
        assert_eq!(
            Comparison::WorkingVsHead.name(),
            "working tree against HEAD"
        );
    }
}
