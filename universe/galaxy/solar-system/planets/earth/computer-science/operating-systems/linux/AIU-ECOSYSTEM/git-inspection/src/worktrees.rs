// One job: the worktrees — the working trees of one repository, and the
// branches or commits they stand on.
//
// A linked worktree shares the repository's objects: it is not a repository
// of its own, and the model says so. The porcelain list is read here, and
// nothing else is: no worktree is created, moved, locked or pruned.

use crate::model::{Divergence, Freshness, Head, Worktree};

/// parse reads the porcelain list of the worktrees. The list is read in
/// either shape it comes in: the one with lines, and the one with NULs.
pub fn parse(output: &str) -> Vec<Worktree> {
    let text = output.replace('\0', "\n");
    let mut worktrees: Vec<Worktree> = Vec::new();
    let mut path = String::new();
    let mut commit = String::new();
    let mut branch = String::new();
    let mut detached = false;
    let mut locked = false;
    let mut prunable = false;
    let mut bare = false;
    let mut seen = false;
    let mut flush = |worktrees: &mut Vec<Worktree>,
                    path: &mut String,
                    commit: &mut String,
                    branch: &mut String,
                    detached: &mut bool,
                    locked: &mut bool,
                    prunable: &mut bool,
                    bare: &mut bool,
                    seen: &mut bool| {
        if !*seen {
            return;
        }
        let head = if *detached {
            Head::Detached(commit.clone())
        } else {
            Head::OnBranch(branch.clone())
        };
        worktrees.push(Worktree {
            path: path.clone(),
            head,
            commit: commit.clone(),
            locked: *locked,
            prunable: *prunable,
            bare: *bare,
            counts: Default::default(),
            divergence: Divergence::Unknown,
            freshness: Freshness::Fresh,
        });
        *path = String::new();
        *commit = String::new();
        *branch = String::new();
        *detached = false;
        *locked = false;
        *prunable = false;
        *bare = false;
        *seen = false;
    };
    for line in text.lines() {
        let line = line.trim_end();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("worktree ") {
            flush(
                &mut worktrees,
                &mut path,
                &mut commit,
                &mut branch,
                &mut detached,
                &mut locked,
                &mut prunable,
                &mut bare,
                &mut seen,
            );
            path = rest.to_string();
            seen = true;
        } else if let Some(rest) = line.strip_prefix("HEAD ") {
            commit = rest.to_string();
        } else if let Some(rest) = line.strip_prefix("branch ") {
            branch = rest.trim_start_matches("refs/heads/").to_string();
        } else if line == "detached" {
            detached = true;
        } else if line == "locked" {
            locked = true;
        } else if line.starts_with("prunable") {
            prunable = true;
        } else if line == "bare" {
            bare = true;
        }
    }
    flush(
        &mut worktrees,
        &mut path,
        &mut commit,
        &mut branch,
        &mut detached,
        &mut locked,
        &mut prunable,
        &mut bare,
        &mut seen,
    );
    worktrees
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_main_worktree_and_a_linked_one_are_two_worktrees() {
        let list = "worktree /repo\nHEAD abcdef\nbranch refs/heads/main\n\nworktree /repo/linked\nHEAD 123456\nbranch refs/heads/feature\n";
        let worktrees = parse(list);
        assert_eq!(worktrees.len(), 2);
        assert_eq!(worktrees[0].path, "/repo");
        assert_eq!(worktrees[0].head.branch(), Some("main".to_string()));
        assert_eq!(worktrees[1].path, "/repo/linked");
        assert_eq!(worktrees[1].head.branch(), Some("feature".to_string()));
    }

    #[test]
    fn a_detached_worktree_names_the_commit_it_stands_on() {
        let list = "worktree /repo/one\nHEAD abcdef\ndetached\n";
        let worktrees = parse(list);
        assert!(worktrees[0].head.is_detached());
        assert_eq!(worktrees[0].commit, "abcdef");
    }

    #[test]
    fn a_locked_and_a_prunable_worktree_say_so() {
        let list = "worktree /repo/one\nHEAD abcdef\nbranch refs/heads/one\nlocked\nprunable gitdir file points to non-existent location\n";
        let worktrees = parse(list);
        assert!(worktrees[0].locked);
        assert!(worktrees[0].prunable);
    }

    #[test]
    fn the_nul_shape_reads_the_same_way() {
        let list = "worktree /repo\0HEAD abcdef\0branch refs/heads/main\0\0worktree /repo/two\0HEAD 123456\0detached\0";
        let worktrees = parse(list);
        assert_eq!(worktrees.len(), 2);
        assert_eq!(worktrees[1].path, "/repo/two");
        assert!(worktrees[1].head.is_detached());
    }
}
