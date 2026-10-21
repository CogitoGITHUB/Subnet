// One job: the model — the states a repository, a file, a branch and a
// buffer can be in, and the names both programs show for them.
//
// The states are separate on purpose. A changed file is not an unpushed
// commit, a clean file on a branch with unpushed commits is clean, and a
// buffer with unsaved text is not a file yet. Nothing here is collapsed
// into one "changed" mark.

use serde_json::{json, Value};

/// WorkingTree is the state of a file in the working tree, against the
/// index.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkingTree {
    /// Clean is a file that matches the index.
    Clean,
    /// Modified is a tracked file whose text changed.
    Modified,
    /// Added is a file the index knows and the tree has.
    Added,
    /// Deleted is a tracked file that is gone from the tree.
    Deleted,
    /// Renamed is a tracked file that moved.
    Renamed,
    /// Copied is a tracked file that was copied.
    Copied,
    /// Untracked is a file the repository does not know.
    Untracked,
    /// TypeChange is a file that is not what it was: a link, a directory.
    TypeChange,
    /// Conflicted is a file with a merge that is not settled.
    Conflicted,
    /// Unknown is a state Git did not report.
    Unknown,
}

impl WorkingTree {
    /// name answers the state as a person reads it.
    pub fn name(&self) -> &'static str {
        match self {
            WorkingTree::Clean => "clean",
            WorkingTree::Modified => "modified",
            WorkingTree::Added => "added",
            WorkingTree::Deleted => "deleted",
            WorkingTree::Renamed => "renamed",
            WorkingTree::Copied => "copied",
            WorkingTree::Untracked => "untracked",
            WorkingTree::TypeChange => "type change",
            WorkingTree::Conflicted => "conflicted",
            WorkingTree::Unknown => "unknown",
        }
    }

    /// mark answers the one character that stands for the state. The mark
    /// carries the meaning on its own: a reader does not need the color.
    pub fn mark(&self) -> &'static str {
        match self {
            WorkingTree::Clean => " ",
            WorkingTree::Modified => "~",
            WorkingTree::Added => "+",
            WorkingTree::Deleted => "-",
            WorkingTree::Renamed => ">",
            WorkingTree::Copied => ">",
            WorkingTree::Untracked => "?",
            WorkingTree::TypeChange => "T",
            WorkingTree::Conflicted => "!",
            WorkingTree::Unknown => "x",
        }
    }

    /// from_letter answers the state of one letter of the porcelain status.
    /// Git writes a dot for "nothing here", not a space.
    pub fn from_letter(letter: char) -> WorkingTree {
        match letter {
            ' ' | '.' => WorkingTree::Clean,
            'M' => WorkingTree::Modified,
            'A' => WorkingTree::Added,
            'D' => WorkingTree::Deleted,
            'R' => WorkingTree::Renamed,
            'C' => WorkingTree::Copied,
            'T' => WorkingTree::TypeChange,
            'U' => WorkingTree::Conflicted,
            '?' => WorkingTree::Untracked,
            '!' => WorkingTree::Unknown,
            _ => WorkingTree::Unknown,
        }
    }
}

/// Index is the state of a file in the index, against HEAD.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Index {
    /// Unchanged is a file the index holds as HEAD holds it.
    Unchanged,
    /// Added is a file the index holds and HEAD does not.
    Added,
    /// Modified is a file the index holds with other text.
    Modified,
    /// Deleted is a file the index no longer holds.
    Deleted,
    /// Renamed is a file that moved in the index.
    Renamed,
    /// Copied is a file that was copied in the index.
    Copied,
    /// Unmerged is a file the index cannot settle.
    Unmerged,
    /// Unknown is a state Git did not report.
    Unknown,
}

impl Index {
    /// name answers the state as a person reads it.
    pub fn name(&self) -> &'static str {
        match self {
            Index::Unchanged => "unchanged",
            Index::Added => "added",
            Index::Modified => "modified",
            Index::Deleted => "deleted",
            Index::Renamed => "renamed",
            Index::Copied => "copied",
            Index::Unmerged => "unmerged",
            Index::Unknown => "unknown",
        }
    }

    /// mark answers the one character that stands for the state.
    pub fn mark(&self) -> &'static str {
        match self {
            Index::Unchanged => " ",
            Index::Added => "+",
            Index::Modified => "~",
            Index::Deleted => "-",
            Index::Renamed => ">",
            Index::Copied => ">",
            Index::Unmerged => "!",
            Index::Unknown => "x",
        }
    }

    /// from_letter answers the state of one letter of the porcelain status.
    /// Git writes a dot for "nothing here", not a space.
    pub fn from_letter(letter: char) -> Index {
        match letter {
            ' ' | '.' => Index::Unchanged,
            'M' => Index::Modified,
            'A' => Index::Added,
            'D' => Index::Deleted,
            'R' => Index::Renamed,
            'C' => Index::Copied,
            'U' => Index::Unmerged,
            _ => Index::Unknown,
        }
    }
}

/// Buffer is the state of an editor buffer against the file on disk. The
/// editor holds this apart from the file's own state: a buffer can hold
/// changes Git cannot see yet.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Buffer {
    /// Saved is a buffer that matches the file on disk.
    Saved,
    /// Unsaved is a buffer with changes that are not on disk.
    Unsaved,
    /// Overlapping is a buffer with changes that touch a change Git can see.
    Overlapping,
    /// Unavailable is a comparison that could not be made.
    Unavailable,
}

impl Buffer {
    /// name answers the state as a person reads it.
    pub fn name(&self) -> &'static str {
        match self {
            Buffer::Saved => "saved",
            Buffer::Unsaved => "unsaved changes",
            Buffer::Overlapping => "unsaved changes over a git change",
            Buffer::Unavailable => "not available",
        }
    }

    /// mark answers the one character that stands for the state.
    pub fn mark(&self) -> &'static str {
        match self {
            Buffer::Saved => " ",
            Buffer::Unsaved => "*",
            Buffer::Overlapping => "!",
            Buffer::Unavailable => "x",
        }
    }
}

/// Head is where the repository stands.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Head {
    /// OnBranch is a branch the repository is on.
    OnBranch(String),
    /// Detached is a commit the repository stands on with no branch.
    Detached(String),
    /// Unborn is a branch with no commit yet.
    Unborn(String),
}

impl Head {
    /// name answers the head as a person reads it.
    pub fn name(&self) -> String {
        match self {
            Head::OnBranch(name) => name.clone(),
            Head::Detached(commit) => format!("detached at {}", short(commit)),
            Head::Unborn(name) => format!("{} (no commits yet)", name),
        }
    }

    /// branch answers the branch name, if the head is on one.
    pub fn branch(&self) -> Option<String> {
        match self {
            Head::OnBranch(name) | Head::Unborn(name) => Some(name.clone()),
            Head::Detached(_) => None,
        }
    }

    /// is_detached answers whether the head stands on no branch.
    pub fn is_detached(&self) -> bool {
        matches!(self, Head::Detached(_))
    }
}

/// Divergence is what the branch has against its upstream. It is never
/// guessed: without the local ref of the upstream, it is unknown.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Divergence {
    /// UpToDate is a branch with nothing ahead and nothing behind.
    UpToDate,
    /// Ahead is a branch with commits the upstream does not have.
    Ahead(u64),
    /// Behind is a branch with commits the upstream has and it does not.
    Behind(u64),
    /// Diverged is a branch with commits on both sides.
    Diverged { ahead: u64, behind: u64 },
    /// Unknown is a branch whose upstream is not here, or whose upstream is
    /// not known.
    Unknown,
}

impl Divergence {
    /// name answers the divergence as a person reads it.
    pub fn name(&self) -> &'static str {
        match self {
            Divergence::UpToDate => "in step with the upstream",
            Divergence::Ahead(_) => "ahead of the upstream",
            Divergence::Behind(_) => "behind the upstream",
            Divergence::Diverged { .. } => "diverged from the upstream",
            Divergence::Unknown => "the upstream is not known here",
        }
    }

    /// mark answers the one character that stands for the divergence.
    pub fn mark(&self) -> &'static str {
        match self {
            Divergence::UpToDate => " ",
            Divergence::Ahead(_) => "^",
            Divergence::Behind(_) => "v",
            Divergence::Diverged { .. } => "<>",
            Divergence::Unknown => "?",
        }
    }

    /// ahead answers how many commits are ahead, when that is known.
    pub fn ahead(&self) -> Option<u64> {
        match self {
            Divergence::Ahead(ahead) => Some(*ahead),
            Divergence::Diverged { ahead, .. } => Some(*ahead),
            _ => None,
        }
    }

    /// behind answers how many commits are behind, when that is known.
    pub fn behind(&self) -> Option<u64> {
        match self {
            Divergence::Behind(behind) => Some(*behind),
            Divergence::Diverged { behind, .. } => Some(*behind),
            _ => None,
        }
    }
}

/// Freshness says how much the answer can be trusted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Freshness {
    /// Fresh is a state that was just read.
    Fresh,
    /// RefreshPending is a state that is being read now.
    RefreshPending,
    /// Stale is a state that was read earlier.
    Stale,
    /// Failed is a state that could not be read.
    Failed,
    /// Unsupported is a thing this Git does not have.
    Unsupported,
}

impl Freshness {
    /// name answers the freshness as a person reads it.
    pub fn name(&self) -> &'static str {
        match self {
            Freshness::Fresh => "fresh",
            Freshness::RefreshPending => "being read",
            Freshness::Stale => "stale",
            Freshness::Failed => "the read failed",
            Freshness::Unsupported => "this git does not have it",
        }
    }

    /// mark answers the one character that stands for the freshness.
    pub fn mark(&self) -> &'static str {
        match self {
            Freshness::Fresh => " ",
            Freshness::RefreshPending => ".",
            Freshness::Stale => "~",
            Freshness::Failed => "x",
            Freshness::Unsupported => "-",
        }
    }
}

/// Counts are how many files are in each state.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    pub staged: usize,
    pub unstaged: usize,
    pub untracked: usize,
    pub conflicted: usize,
}

impl Counts {
    /// to_json answers the counts as data.
    pub fn to_json(&self) -> Value {
        json!({
            "staged": self.staged,
            "unstaged": self.unstaged,
            "untracked": self.untracked,
            "conflicted": self.conflicted,
        })
    }
}

/// FileStatus is one file: what the index holds of it and what the working
/// tree holds of it. The two are apart on purpose.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileStatus {
    pub path: String,
    pub index: Index,
    pub working: WorkingTree,
}

impl FileStatus {
    /// is_staged answers whether the index holds a change of this file.
    pub fn is_staged(&self) -> bool {
        self.index != Index::Unchanged
    }

    /// is_unstaged answers whether the working tree holds a change of this
    /// file that the index does not have.
    pub fn is_unstaged(&self) -> bool {
        self.working != WorkingTree::Clean && self.working != WorkingTree::Untracked
    }

    /// to_json answers the file as data.
    pub fn to_json(&self) -> Value {
        json!({
            "path": self.path,
            "index": self.index.name(),
            "index-mark": self.index.mark(),
            "working": self.working.name(),
            "working-mark": self.working.mark(),
        })
    }
}

/// Commit is one commit: who wrote it, when, what it says, and the files it
/// touched.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Commit {
    pub id: String,
    pub short: String,
    pub author: String,
    pub email: String,
    pub when: i64,
    pub date: String,
    pub summary: String,
    pub files: Vec<String>,
}

impl Commit {
    /// to_json answers the commit as data.
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "short": self.short,
            "author": self.author,
            "email": self.email,
            "when": self.when,
            "date": self.date,
            "summary": self.summary,
            "files": self.files,
        })
    }
}

/// HunkLineKind is what one line of a hunk is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HunkLineKind {
    Context,
    Added,
    Removed,
}

impl HunkLineKind {
    /// mark answers the one character that stands for the line.
    pub fn mark(&self) -> &'static str {
        match self {
            HunkLineKind::Context => " ",
            HunkLineKind::Added => "+",
            HunkLineKind::Removed => "-",
        }
    }

    /// name answers the kind as a person reads it.
    pub fn name(&self) -> &'static str {
        match self {
            HunkLineKind::Context => "context",
            HunkLineKind::Added => "added",
            HunkLineKind::Removed => "removed",
        }
    }
}

/// HunkLine is one line of a hunk: what it is, what it says, and where it
/// was and where it is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HunkLine {
    pub kind: HunkLineKind,
    pub text: String,
    pub old_line: Option<u64>,
    pub new_line: Option<u64>,
}

/// Hunk is one changed piece of a file: where it is on both sides, and the
/// lines that changed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hunk {
    pub old_start: u64,
    pub old_lines: u64,
    pub new_start: u64,
    pub new_lines: u64,
    pub lines: Vec<HunkLine>,
}

/// Worktree is one working tree of a repository. A linked worktree shares
/// the repository's object database; it is not a repository of its own.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Worktree {
    pub path: String,
    pub head: Head,
    pub commit: String,
    pub locked: bool,
    pub prunable: bool,
    pub bare: bool,
    pub counts: Counts,
    pub divergence: Divergence,
    pub freshness: Freshness,
}

impl Worktree {
    /// to_json answers the worktree as data.
    pub fn to_json(&self) -> Value {
        json!({
            "path": self.path,
            "head": self.head.name(),
            "branch": self.head.branch(),
            "detached": self.head.is_detached(),
            "commit": self.commit,
            "locked": self.locked,
            "prunable": self.prunable,
            "bare": self.bare,
            "counts": self.counts.to_json(),
            "divergence": self.divergence.name(),
            "ahead": self.divergence.ahead(),
            "behind": self.divergence.behind(),
            "freshness": self.freshness.name(),
        })
    }
}

/// Repository is one repository: where it is, and every worktree of it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Repository {
    /// root is the top of the main worktree.
    pub root: String,
    /// git_dir is the directory that holds this worktree's own Git files.
    pub git_dir: String,
    /// common_dir is the directory that holds the objects every worktree
    /// shares.
    pub common_dir: String,
    /// worktrees are the working trees of this repository.
    pub worktrees: Vec<Worktree>,
}

impl Repository {
    /// is_linked answers whether this repository has worktrees besides the
    /// main one: a linked worktree shares the objects of the repository and
    /// is not a repository of its own.
    pub fn is_linked(&self) -> bool {
        self.worktrees.len() > 1
    }

    /// to_json answers the repository as data.
    pub fn to_json(&self) -> Value {
        json!({
            "root": self.root,
            "git-dir": self.git_dir,
            "common-dir": self.common_dir,
            "linked": self.is_linked(),
            "worktrees": self.worktrees.iter().map(|worktree| worktree.to_json()).collect::<Vec<Value>>(),
        })
    }
}

/// RepositoryStatus is what one worktree holds right now: where it stands,
/// what changed, and how much of that answer is fresh.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RepositoryStatus {
    pub head: Head,
    pub upstream: Option<String>,
    pub divergence: Divergence,
    pub files: Vec<FileStatus>,
    pub counts: Counts,
    pub freshness: Freshness,
}

impl RepositoryStatus {
    /// to_json answers the status as data.
    pub fn to_json(&self) -> Value {
        json!({
            "head": self.head.name(),
            "branch": self.head.branch(),
            "detached": self.head.is_detached(),
            "upstream": self.upstream,
            "divergence": self.divergence.name(),
            "ahead": self.divergence.ahead(),
            "behind": self.divergence.behind(),
            "counts": self.counts.to_json(),
            "files": self.files.iter().map(|file| file.to_json()).collect::<Vec<Value>>(),
            "freshness": self.freshness.name(),
        })
    }
}

/// short answers the short form of a commit id.
pub fn short(commit: &str) -> String {
    commit.chars().take(7).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_marks_carry_the_meaning_on_their_own() {
        // A reader with no colors must still tell the states apart.
        let marks = [
            WorkingTree::Modified.mark(),
            WorkingTree::Added.mark(),
            WorkingTree::Deleted.mark(),
            WorkingTree::Untracked.mark(),
            WorkingTree::Conflicted.mark(),
        ];
        let mut unique = marks.to_vec();
        unique.sort();
        unique.dedup();
        assert_eq!(unique.len(), marks.len(), "two states share a mark");
    }

    #[test]
    fn a_change_in_the_index_and_a_change_in_the_tree_are_apart() {
        let staged = FileStatus {
            path: "a.txt".to_string(),
            index: Index::Modified,
            working: WorkingTree::Clean,
        };
        assert!(staged.is_staged());
        assert!(!staged.is_unstaged());
        let unstaged = FileStatus {
            path: "a.txt".to_string(),
            index: Index::Unchanged,
            working: WorkingTree::Modified,
        };
        assert!(!unstaged.is_staged());
        assert!(unstaged.is_unstaged());
    }

    #[test]
    fn an_unknown_divergence_is_not_an_up_to_date_branch() {
        assert_ne!(Divergence::Unknown, Divergence::UpToDate);
        assert_eq!(Divergence::Unknown.ahead(), None);
        assert_eq!(Divergence::Unknown.behind(), None);
    }

    #[test]
    fn a_detached_head_names_the_commit_it_stands_on() {
        let head = Head::Detached("0123456789abcdef".to_string());
        assert!(head.is_detached());
        assert_eq!(head.name(), "detached at 0123456");
        assert_eq!(head.branch(), None);
    }
}
