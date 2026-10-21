// One job: the Git inspection layer — the one read-only model of a
// repository that the text editor and the terminal multiplexer both read.
//
// The layer owns the discovery, the commands, the parsing, the states and
// the freshness. It owns no presentation: the programs show what it says
// in their own ways, and they say the same thing, because there is one
// model and one parser.
//
// The layer is read-only. The commands it can run are named in
// =command.rs=, and every one of them reads: nothing here stages,
// commits, checks out, merges, stashes, fetches, pushes or changes a
// worktree. A change of state is a different program, with declared
// permissions.
//
// The layer never blocks a program while it reads: every answer carries
// how fresh it is, and a reader that wants a fresher answer asks again.

pub mod branch;
pub mod command;
pub mod diff;
pub mod history;
pub mod model;
pub mod status;
pub mod worktrees;

#[cfg(test)]
mod repositories;

use std::path::{Path, PathBuf};

use command::{Comparison, GitCommand};

/// Git is one repository, opened at a path.
#[derive(Clone, Debug)]
pub struct Git {
    root: PathBuf,
}

/// The error of this layer is a sentence: it says what could not be done
/// and why, in the words of the tool that refused.
pub type Error = String;

impl Git {
    /// open answers the repository at a path, or says why there is none.
    pub fn open(path: &Path) -> Result<Git, Error> {
        if !command::git_is_here() {
            return Err("git is not on this machine".to_string());
        }
        let answer = command::run(
            path,
            GitCommand::Repository,
            None,
            Comparison::WorkingVsIndex,
            None,
        )?;
        if !answer.ok() {
            return Err(format!(
                "{} is not inside a repository: {}",
                path.display(),
                answer.failed()
            ));
        }
        let lines: Vec<&str> = answer.out.lines().collect();
        if lines.len() < 5 {
            return Err(format!(
                "{} is not inside a repository",
                path.display()
            ));
        }
        if lines[3].trim() != "true" {
            return Err(format!(
                "{} is not inside a working tree",
                path.display()
            ));
        }
        Ok(Git {
            root: PathBuf::from(lines[0].trim()),
        })
    }

    /// root answers the top of the main worktree.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// repository answers the repository and every worktree of it.
    pub fn repository(&self) -> Result<model::Repository, Error> {
        let answer = command::run(
            &self.root,
            GitCommand::Repository,
            None,
            Comparison::WorkingVsIndex,
            None,
        )?;
        let lines: Vec<&str> = answer.out.lines().collect();
        if lines.len() < 5 {
            return Err("the repository did not say where it is".to_string());
        }
        let mut repository = model::Repository {
            root: lines[0].trim().to_string(),
            git_dir: lines[1].trim().to_string(),
            common_dir: lines[2].trim().to_string(),
            worktrees: Vec::new(),
        };
        repository.worktrees = self.worktrees();
        Ok(repository)
    }

    /// worktrees answers every working tree of this repository.
    pub fn worktrees(&self) -> Vec<model::Worktree> {
        let answer = command::run(
            &self.root,
            GitCommand::Worktrees,
            None,
            Comparison::WorkingVsIndex,
            None,
        );
        let answer = match answer {
            Ok(answer) => answer,
            Err(_) => return Vec::new(),
        };
        let mut worktrees = worktrees::parse(&answer.out);
        // The counts and the distance of each worktree are read in that
        // worktree itself: a worktree is a place, and Git is asked there.
        for worktree in worktrees.iter_mut() {
            let path = PathBuf::from(&worktree.path);
            if !path.exists() {
                worktree.freshness = model::Freshness::Stale;
                continue;
            }
            let state = self.status_at(&path);
            worktree.counts = state.counts;
            worktree.divergence = state.divergence;
        }
        worktrees
    }

    /// status answers what this worktree holds now.
    pub fn status(&self) -> model::RepositoryStatus {
        self.status_at(&self.root)
    }

    /// status_at answers what the worktree at a path holds now.
    pub fn status_at(&self, path: &Path) -> model::RepositoryStatus {
        let answer = command::run(
            path,
            GitCommand::Status,
            None,
            Comparison::WorkingVsIndex,
            None,
        );
        let answer = match answer {
            Ok(answer) => answer,
            Err(why) => {
                let mut empty = status::parse("");
                empty.freshness = model::Freshness::Failed;
                let _ = why;
                return empty;
            }
        };
        if !answer.ok() {
            let mut failed = status::parse("");
            failed.freshness = model::Freshness::Failed;
            return failed;
        }
        status::parse(&answer.out)
    }

    /// branches answers the local branches and how far they are from their
    /// upstream.
    pub fn branches(&self) -> Vec<branch::Branch> {
        let answer = command::run(
            &self.root,
            GitCommand::Branches,
            None,
            Comparison::WorkingVsIndex,
            None,
        );
        match answer {
            Ok(answer) => branch::parse(&answer.out),
            Err(_) => Vec::new(),
        }
    }

    /// diff answers the hunks of one comparison.
    pub fn diff(
        &self,
        path: Option<&str>,
        comparison: Comparison,
    ) -> Result<Vec<model::Hunk>, Error> {
        let answer = command::run(
            &self.root,
            GitCommand::Diff,
            path,
            comparison,
            None,
        )?;
        if !answer.ok() {
            return Err(answer.failed());
        }
        Ok(diff::parse(&answer.out))
    }

    /// diffs answers the diff of a whole tree: every file that changed, with
    /// the hunks of each. The comparison is named by the caller and is
    /// never mixed with another one.
    pub fn diffs(
        &self,
        comparison: Comparison,
    ) -> Result<Vec<diff::FileDiff>, Error> {
        let answer = command::run(
            &self.root,
            GitCommand::Diff,
            None,
            comparison,
            None,
        )?;
        if !answer.ok() {
            return Err(answer.failed());
        }
        Ok(diff::parse_files(&answer.out))
    }

    /// log answers the history, newest first, of a path or of everything.
    pub fn log(&self, path: Option<&str>) -> Result<Vec<model::Commit>, Error> {
        let answer = command::run(
            &self.root,
            GitCommand::Log,
            path,
            Comparison::WorkingVsIndex,
            None,
        )?;
        if !answer.ok() {
            return Err(answer.failed());
        }
        Ok(history::parse(&answer.out))
    }

    /// show answers one commit: what it said and what it touched.
    pub fn show(&self, commit: &str) -> Result<Vec<model::Commit>, Error> {
        let answer = command::run(
            &self.root,
            GitCommand::Show,
            None,
            Comparison::WorkingVsIndex,
            Some(commit),
        )?;
        if !answer.ok() {
            return Err(answer.failed());
        }
        Ok(history::parse(&answer.out))
    }

    /// blame answers the line history of a file.
    pub fn blame(&self, path: &str) -> Result<Vec<BlameLine>, Error> {
        let answer = command::run(
            &self.root,
            GitCommand::Blame,
            Some(path),
            Comparison::WorkingVsIndex,
            None,
        )?;
        if !answer.ok() {
            return Err(answer.failed());
        }
        Ok(parse_blame(&answer.out))
    }

    /// file_at answers the contents of a file at a commit. It reads the
    /// object; it does not check it out and it does not touch the file.
    pub fn file_at(&self, object: &str) -> Result<String, Error> {
        let answer = command::run(
            &self.root,
            GitCommand::FileAt,
            None,
            Comparison::WorkingVsIndex,
            Some(object),
        )?;
        if !answer.ok() {
            return Err(answer.failed());
        }
        Ok(answer.out)
    }
}

/// BlameLine is one line of a file and the commit that last touched it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlameLine {
    pub commit: String,
    pub author: String,
    pub when: i64,
    pub line: u64,
    pub text: String,
}

/// parse_blame reads the porcelain blame: the header of a line, then its
/// fields, then the text.
pub fn parse_blame(output: &str) -> Vec<BlameLine> {
    let mut lines: Vec<BlameLine> = Vec::new();
    let mut commit = String::new();
    let mut author = String::new();
    let mut when: i64 = 0;
    let mut number: u64 = 0;
    for line in output.lines() {
        if line.starts_with('\t') {
            lines.push(BlameLine {
                commit: commit.clone(),
                author: author.clone(),
                when,
                line: number,
                text: line[1..].to_string(),
            });
            continue;
        }
        // The header of a line of blame is the commit, the line it was, the
        // line it is, and how many lines the group covers.
        let head: Vec<&str> = line.split_whitespace().collect();
        if head.len() >= 3 && head[0].len() == 40 && head[0].chars().all(|one| one.is_ascii_hexdigit()) {
            commit = head[0].to_string();
            number = head[2].parse().unwrap_or(0);
        }
        if let Some(rest) = line.strip_prefix("author ") {
            author = rest.to_string();
        }
        if let Some(rest) = line.strip_prefix("author-time ") {
            when = rest.trim().parse().unwrap_or(0);
        }
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_that_is_not_a_repository_is_refused_by_name() {
        let error = Git::open(Path::new("/tmp")).expect_err("it is not a repository");
        assert!(
            error.contains("not inside a working tree") || error.contains("not inside a repository"),
            "the refusal says why: {}",
            error
        );
    }

    #[test]
    fn the_blame_lines_carry_their_commit() {
        let output = "0123456789abcdef0123456789abcdef01234567 12 10 1\nauthor Shape\nauthor-time 1700000000\n\tthe text\n";
        let lines = parse_blame(output);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].text, "the text");
        assert_eq!(lines[0].line, 10);
        assert_eq!(lines[0].author, "Shape");
    }
}
