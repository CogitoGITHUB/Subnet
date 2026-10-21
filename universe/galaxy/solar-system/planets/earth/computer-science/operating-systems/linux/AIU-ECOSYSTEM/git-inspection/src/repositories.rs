// One job: the real repositories the tests are built on.
//
// Every test here builds a real repository with Git itself and asks the
// layer what Git says. The layer never writes; the fixture does, because a
// repository has to have something in it to be looked at.

#![cfg(test)]

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::command::Comparison;
use crate::model::{Divergence, Freshness, Index, WorkingTree};
use crate::Git;

static COUNTER: AtomicUsize = AtomicUsize::new(0);

/// git_in runs one Git command in a directory and says whether it worked.
fn git_in(dir: &Path, args: &[&str]) -> bool {
    Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "Shape")
        .env("GIT_AUTHOR_EMAIL", "shape@example.org")
        .env("GIT_COMMITTER_NAME", "Shape")
        .env("GIT_COMMITTER_EMAIL", "shape@example.org")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

/// git_says runs one Git command and answers what it printed.
fn git_says(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .output()
        .expect("git runs");
    String::from_utf8_lossy(&output.stdout).to_string()
}

/// a_repository answers a new repository with one commit in it.
fn a_repository(name: &str) -> PathBuf {
    let at = std::env::temp_dir().join(format!(
        "git-inspection-{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_dir_all(&at);
    std::fs::create_dir_all(&at).expect("the directory is made");
    assert!(git_in(&at, &["init", "-b", "main"]), "the repository is made");
    std::fs::write(at.join("file.txt"), "one\n").expect("the file is written");
    git_in(&at, &["add", "file.txt"]);
    git_in(&at, &["commit", "-m", "the first commit"]);
    let _ = name;
    at
}

#[test]
fn a_fresh_repository_is_clean_and_knows_no_upstream() {
    let repo = a_repository("fresh");
    let git = Git::open(&repo).expect("the repository opens");
    let status = git.status();
    assert_eq!(status.files.len(), 0, "nothing changed yet");
    assert_eq!(status.counts.staged, 0);
    assert_eq!(status.counts.unstaged, 0);
    assert_eq!(status.counts.untracked, 0);
    assert_eq!(status.head.branch(), Some("main".to_string()));
    // No upstream is known, and that is not the same as being up to date.
    assert_eq!(status.divergence, Divergence::Unknown);
    assert_eq!(status.freshness, Freshness::Fresh);
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn a_modified_file_is_an_unstaged_change() {
    let repo = a_repository("modified");
    std::fs::write(repo.join("file.txt"), "two\n").expect("the file is written");
    let git = Git::open(&repo).expect("the repository opens");
    let status = git.status();
    assert_eq!(status.counts.unstaged, 1);
    assert_eq!(status.counts.staged, 0);
    assert_eq!(status.files[0].working, WorkingTree::Modified);
    assert_eq!(status.files[0].index, Index::Unchanged);
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn a_staged_file_is_a_staged_change_and_not_an_unstaged_one() {
    let repo = a_repository("staged");
    std::fs::write(repo.join("file.txt"), "two\n").expect("the file is written");
    git_in(&repo, &["add", "file.txt"]);
    let git = Git::open(&repo).expect("the repository opens");
    let status = git.status();
    assert_eq!(status.counts.staged, 1);
    assert_eq!(status.counts.unstaged, 0);
    assert_eq!(status.files[0].index, Index::Modified);
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn a_file_that_is_staged_and_changed_again_is_both() {
    let repo = a_repository("both");
    std::fs::write(repo.join("file.txt"), "two\n").expect("the file is written");
    git_in(&repo, &["add", "file.txt"]);
    std::fs::write(repo.join("file.txt"), "three\n").expect("the file is written");
    let git = Git::open(&repo).expect("the repository opens");
    let status = git.status();
    assert_eq!(status.counts.staged, 1);
    assert_eq!(status.counts.unstaged, 1);
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn an_untracked_file_is_untracked_and_not_a_change() {
    let repo = a_repository("untracked");
    std::fs::write(repo.join("new.txt"), "new\n").expect("the file is written");
    let git = Git::open(&repo).expect("the repository opens");
    let status = git.status();
    assert_eq!(status.counts.untracked, 1);
    assert_eq!(status.counts.staged, 0);
    assert_eq!(status.counts.unstaged, 0);
    assert_eq!(status.files[0].working, WorkingTree::Untracked);
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn a_deleted_file_is_deleted() {
    let repo = a_repository("deleted");
    std::fs::remove_file(repo.join("file.txt")).expect("the file is gone");
    let git = Git::open(&repo).expect("the repository opens");
    let status = git.status();
    assert_eq!(status.files[0].working, WorkingTree::Deleted);
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn a_renamed_file_is_renamed() {
    let repo = a_repository("renamed");
    git_in(&repo, &["mv", "file.txt", "other.txt"]);
    let git = Git::open(&repo).expect("the repository opens");
    let status = git.status();
    // The index holds the rename and the tree holds what the index holds.
    assert_eq!(status.files[0].index, Index::Renamed);
    assert_eq!(status.files[0].working, WorkingTree::Clean);
    assert_eq!(status.counts.staged, 1);
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn a_conflict_is_a_conflict() {
    let repo = a_repository("conflict");
    git_in(&repo, &["checkout", "-b", "other"]);
    std::fs::write(repo.join("file.txt"), "theirs\n").expect("the file is written");
    git_in(&repo, &["commit", "-am", "theirs"]);
    git_in(&repo, &["checkout", "main"]);
    std::fs::write(repo.join("file.txt"), "ours\n").expect("the file is written");
    git_in(&repo, &["commit", "-am", "ours"]);
    git_in(&repo, &["merge", "other"]);
    let git = Git::open(&repo).expect("the repository opens");
    let status = git.status();
    assert_eq!(status.counts.conflicted, 1, "the merge is not settled");
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn a_linked_worktree_is_a_second_worktree_of_one_repository() {
    let repo = a_repository("worktree");
    let linked = repo.join("linked");
    assert!(
        git_in(&repo, &["worktree", "add", "-b", "side", linked.to_str().unwrap()]),
        "the worktree is made"
    );
    let git = Git::open(&repo).expect("the repository opens");
    let repository = git.repository().expect("the repository answers");
    assert_eq!(repository.worktrees.len(), 2);
    assert!(repository.is_linked(), "the linked worktree shares the objects");
    let names: Vec<String> = repository
        .worktrees
        .iter()
        .map(|worktree| worktree.head.branch().unwrap_or_default())
        .collect();
    assert!(names.contains(&"main".to_string()));
    assert!(names.contains(&"side".to_string()));
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn a_detached_worktree_says_it_is_detached() {
    let repo = a_repository("detached");
    let linked = repo.join("detached-one");
    let head = git_says(&repo, &["rev-parse", "HEAD"]);
    assert!(
        git_in(&repo, &["worktree", "add", "--detach", linked.to_str().unwrap(), head.trim()]),
        "the worktree is made"
    );
    let git = Git::open(&repo).expect("the repository opens");
    let repository = git.repository().expect("the repository answers");
    let detached = repository
        .worktrees
        .iter()
        .find(|worktree| worktree.path.ends_with("detached-one"))
        .expect("the worktree is there");
    assert!(detached.head.is_detached());
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn a_repository_with_spaces_in_its_path_is_found() {
    let at = std::env::temp_dir().join(format!(
        "git inspection spaces {}",
        COUNTER.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_dir_all(&at);
    std::fs::create_dir_all(&at).expect("the directory is made");
    assert!(git_in(&at, &["init", "-b", "main"]), "the repository is made");
    std::fs::write(at.join("a file.txt"), "one\n").expect("the file is written");
    git_in(&at, &["add", "a file.txt"]);
    git_in(&at, &["commit", "-m", "first"]);
    let git = Git::open(&at).expect("the repository opens");
    let status = git.status();
    assert_eq!(status.files.len(), 0);
    let _ = std::fs::remove_dir_all(&at);
}

#[test]
fn a_file_with_odd_characters_in_its_name_is_one_file() {
    let repo = a_repository("odd names");
    let name = "a file with spaces and \"quotes\".txt";
    std::fs::write(repo.join(name), "one\n").expect("the file is written");
    let git = Git::open(&repo).expect("the repository opens");
    let status = git.status();
    assert_eq!(status.files.len(), 1);
    assert_eq!(status.files[0].path, name);
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn the_diff_says_which_lines_were_added_and_which_were_removed() {
    let repo = a_repository("diff");
    std::fs::write(repo.join("file.txt"), "alpha\n").expect("the file is written");
    let git = Git::open(&repo).expect("the repository opens");
    let hunks = git
        .diff(Some("file.txt"), Comparison::WorkingVsIndex)
        .expect("the diff answers");
    assert_eq!(hunks.len(), 1);
    let kinds: Vec<&str> = hunks[0].lines.iter().map(|line| line.kind.name()).collect();
    assert!(kinds.contains(&"added"), "the added lines are there: {:?}", kinds);
    assert!(kinds.contains(&"removed"), "the removed lines are there: {:?}", kinds);
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn the_history_says_what_the_commits_were() {
    let repo = a_repository("history");
    std::fs::write(repo.join("file.txt"), "two\n").expect("the file is written");
    git_in(&repo, &["commit", "-am", "the second commit"]);
    let git = Git::open(&repo).expect("the repository opens");
    let commits = git.log(Some("file.txt")).expect("the history answers");
    assert_eq!(commits.len(), 2);
    assert_eq!(commits[0].summary, "the second commit");
    assert_eq!(commits[0].files, vec!["file.txt".to_string()]);
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn the_inspection_changes_nothing() {
    let repo = a_repository("safety");
    std::fs::write(repo.join("file.txt"), "two\n").expect("the file is written");
    git_in(&repo, &["add", "file.txt"]);
    std::fs::write(repo.join("new.txt"), "new\n").expect("the file is written");

    let before_head = git_says(&repo, &["rev-parse", "HEAD"]);
    let before_refs = git_says(&repo, &["show-ref"]);
    let before_status = git_says(&repo, &["status", "--porcelain=v2"]);
    let before_index = std::fs::read(repo.join(".git").join("index")).unwrap_or_default();
    let before_worktrees = git_says(&repo, &["worktree", "list", "--porcelain"]);
    let before_files = list_files(&repo);

    let git = Git::open(&repo).expect("the repository opens");
    let _ = git.status();
    let _ = git.branches();
    let _ = git.worktrees();
    let _ = git.repository();
    let _ = git.diff(Some("file.txt"), Comparison::WorkingVsIndex);
    let _ = git.diff(Some("file.txt"), Comparison::WorkingVsHead);
    let _ = git.log(Some("file.txt"));
    let _ = git.show("HEAD");
    let _ = git.blame("file.txt");

    assert_eq!(before_head, git_says(&repo, &["rev-parse", "HEAD"]), "HEAD moved");
    assert_eq!(before_refs, git_says(&repo, &["show-ref"]), "a ref moved");
    assert_eq!(
        before_status,
        git_says(&repo, &["status", "--porcelain=v2"]),
        "the status changed"
    );
    assert_eq!(
        before_index,
        std::fs::read(repo.join(".git").join("index")).unwrap_or_default(),
        "the index changed"
    );
    assert_eq!(
        before_worktrees,
        git_says(&repo, &["worktree", "list", "--porcelain"]),
        "the worktrees changed"
    );
    assert_eq!(before_files, list_files(&repo), "a file changed");
    let _ = std::fs::remove_dir_all(&repo);
}

/// list_files answers what the working tree holds, so a change in it is
/// seen.
fn list_files(repo: &Path) -> Vec<String> {
    let mut files: Vec<String> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(repo) {
        for entry in entries.flatten() {
            files.push(entry.file_name().to_string_lossy().to_string());
        }
    }
    files.sort();
    files
}
