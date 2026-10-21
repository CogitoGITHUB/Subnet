// One job: the status — the porcelain v2 status of a worktree, read as the
// model.
//
// The status is read with the porcelain v2 format and NUL separators, so a
// path with a space, a quote or a newline in it is one path and stays one
// path. The letters Git writes are turned into the model's states here, and
// nowhere else: both programs read the same states because there is only
// one place that turns them.

use crate::model::{Counts, Divergence, FileStatus, Freshness, Head, Index, RepositoryStatus, WorkingTree};

/// parse reads the porcelain v2 status of one worktree.
pub fn parse(output: &str) -> RepositoryStatus {
    let entries: Vec<&str> = output.split('\0').filter(|entry| !entry.is_empty()).collect();
    let mut head = Head::Unborn(String::new());
    let mut upstream: Option<String> = None;
    let mut divergence = Divergence::Unknown;
    let mut files: Vec<FileStatus> = Vec::new();
    let mut at = 0;
    while at < entries.len() {
        let entry = entries[at];
        if let Some(rest) = entry.strip_prefix("# branch.oid ") {
            if rest != "(initial)" {
                head = match &head {
                    Head::OnBranch(name) => Head::OnBranch(name.clone()),
                    _ => Head::Detached(rest.to_string()),
                };
            }
        } else if let Some(rest) = entry.strip_prefix("# branch.head ") {
            if rest == "(detached)" {
                head = Head::Detached(String::new());
            } else {
                head = Head::OnBranch(rest.to_string());
            }
        } else if let Some(rest) = entry.strip_prefix("# branch.upstream ") {
            upstream = Some(rest.to_string());
        } else if let Some(rest) = entry.strip_prefix("# branch.ab ") {
            divergence = read_ab(rest);
        } else if entry.starts_with("1 ") {
            let parts: Vec<&str> = entry.splitn(9, ' ').collect();
            if parts.len() == 9 {
                let letters = parts[1].chars().collect::<Vec<char>>();
                let (index_letter, working_letter) = (
                    letters.first().copied().unwrap_or(' '),
                    letters.get(1).copied().unwrap_or(' '),
                );
                files.push(FileStatus {
                    path: parts[8].to_string(),
                    index: Index::from_letter(index_letter),
                    working: WorkingTree::from_letter(working_letter),
                });
            }
        } else if entry.starts_with("2 ") {
            let parts: Vec<&str> = entry.splitn(10, ' ').collect();
            if parts.len() == 10 {
                let letters = parts[1].chars().collect::<Vec<char>>();
                let (index_letter, working_letter) = (
                    letters.first().copied().unwrap_or(' '),
                    letters.get(1).copied().unwrap_or(' '),
                );
                // The name the file had comes next, as its own field, and
                // it is not a record of its own.
                files.push(FileStatus {
                    path: parts[9].to_string(),
                    index: Index::from_letter(index_letter),
                    working: WorkingTree::from_letter(working_letter),
                });
                at += 1;
            }
        } else if entry.starts_with("u ") {
            let parts: Vec<&str> = entry.splitn(11, ' ').collect();
            if parts.len() == 11 {
                let path = parts[10].to_string();
                files.push(FileStatus {
                    path,
                    index: Index::Unmerged,
                    working: WorkingTree::Conflicted,
                });
            }
        } else if let Some(path) = entry.strip_prefix("? ") {
            files.push(FileStatus {
                path: path.to_string(),
                index: Index::Unchanged,
                working: WorkingTree::Untracked,
            });
        }
        at += 1;
    }
    // The head of a branch that has no commit yet is the branch itself.
    if let Head::Unborn(name) = &head {
        head = Head::Unborn(name.clone());
    }
    let counts = count(&files);
    RepositoryStatus {
        head,
        upstream,
        divergence,
        files,
        counts,
        freshness: Freshness::Fresh,
    }
}

/// read_ab reads the ahead and behind Git wrote: "+2 -1".
fn read_ab(text: &str) -> Divergence {
    let mut ahead: u64 = 0;
    let mut behind: u64 = 0;
    for piece in text.split_whitespace() {
        if let Some(number) = piece.strip_prefix('+') {
            ahead = number.parse().unwrap_or(0);
        } else if let Some(number) = piece.strip_prefix('-') {
            behind = number.parse().unwrap_or(0);
        }
    }
    match (ahead, behind) {
        (0, 0) => Divergence::UpToDate,
        (ahead, 0) => Divergence::Ahead(ahead),
        (0, behind) => Divergence::Behind(behind),
        (ahead, behind) => Divergence::Diverged { ahead, behind },
    }
}

/// count answers how many files are in each state.
pub fn count(files: &[FileStatus]) -> Counts {
    let mut counts = Counts::default();
    for file in files {
        if file.index == Index::Unmerged || file.working == WorkingTree::Conflicted {
            counts.conflicted += 1;
            continue;
        }
        if file.working == WorkingTree::Untracked {
            counts.untracked += 1;
            continue;
        }
        if file.index != Index::Unchanged {
            counts.staged += 1;
        }
        if file.working != WorkingTree::Clean {
            counts.unstaged += 1;
        }
    }
    counts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_modified_file_is_modified_in_the_tree_and_unchanged_in_the_index() {
        let status = parse("1 .M N... 100644 100644 100644 aaaa bbbb file.txt\0");
        assert_eq!(status.files.len(), 1);
        assert_eq!(status.files[0].path, "file.txt");
        assert_eq!(status.files[0].index, Index::Unchanged);
        assert_eq!(status.files[0].working, WorkingTree::Modified);
        assert_eq!(status.counts.unstaged, 1);
        assert_eq!(status.counts.staged, 0);
    }

    #[test]
    fn a_staged_file_is_staged_and_clean_in_the_tree() {
        let status = parse("1 M. N... 100644 100644 100644 aaaa bbbb file.txt\0");
        assert_eq!(status.files[0].index, Index::Modified);
        assert_eq!(status.files[0].working, WorkingTree::Clean);
        assert_eq!(status.counts.staged, 1);
        assert_eq!(status.counts.unstaged, 0);
    }

    #[test]
    fn a_file_that_is_staged_and_changed_again_is_both() {
        let status = parse("1 MM N... 100644 100644 100644 aaaa bbbb file.txt\0");
        assert_eq!(status.counts.staged, 1);
        assert_eq!(status.counts.unstaged, 1);
    }

    #[test]
    fn an_untracked_file_is_not_a_change_of_the_index() {
        let status = parse("? new.txt\0");
        assert_eq!(status.files[0].working, WorkingTree::Untracked);
        assert_eq!(status.counts.untracked, 1);
        assert_eq!(status.counts.staged, 0);
        assert_eq!(status.counts.unstaged, 0);
    }

    #[test]
    fn a_path_with_spaces_is_one_path() {
        let status = parse("1 .M N... 100644 100644 100644 aaaa bbbb a file with spaces.txt\0");
        assert_eq!(status.files[0].path, "a file with spaces.txt");
    }

    #[test]
    fn a_conflicted_file_is_a_conflict_and_not_a_change() {
        let status = parse("u UU N... 100644 100644 100644 100644 aaaa bbbb cccc file.txt\0");
        assert_eq!(status.counts.conflicted, 1);
        assert_eq!(status.files[0].index, Index::Unmerged);
    }

    #[test]
    fn the_branch_and_its_distance_are_read_apart() {
        let status = parse("# branch.oid abcdef\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0");
        assert_eq!(status.head.branch(), Some("main".to_string()));
        assert_eq!(status.upstream, Some("origin/main".to_string()));
        assert_eq!(status.divergence, Divergence::Diverged { ahead: 2, behind: 1 });
    }

    #[test]
    fn a_branch_with_no_upstream_is_unknown_and_not_up_to_date() {
        let status = parse("# branch.oid abcdef\0# branch.head main\0");
        assert_eq!(status.divergence, Divergence::Unknown);
        assert_ne!(status.divergence, Divergence::UpToDate);
    }

    #[test]
    fn a_detached_head_is_detached() {
        let status = parse("# branch.oid abcdef\0# branch.head (detached)\0");
        assert!(status.head.is_detached());
    }
}
