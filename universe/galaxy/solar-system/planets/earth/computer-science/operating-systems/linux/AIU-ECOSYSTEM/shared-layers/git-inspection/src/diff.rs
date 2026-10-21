// One job: the diff — the hunks of a comparison, with the lines that
// changed and where they were and where they are.
//
// The comparison is named by the caller and is never mixed: the working
// tree against the index, the index against HEAD, and the working tree
// against HEAD are three different answers.

use crate::command::Comparison;
use crate::model::{Hunk, HunkLine, HunkLineKind};

/// FileDiff is the diff of one file: the hunks that changed it, and the
/// name it has. A diff of a whole tree is a list of these.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileDiff {
    pub path: String,
    pub hunks: Vec<Hunk>,
}

/// parse reads a unified diff into its hunks.
pub fn parse(output: &str) -> Vec<Hunk> {
    let mut hunks: Vec<Hunk> = Vec::new();
    let mut current: Option<Hunk> = None;
    let mut old_line: u64 = 0;
    let mut new_line: u64 = 0;
    for line in output.lines() {
        if line.starts_with("@@") {
            if let Some(hunk) = current.take() {
                hunks.push(hunk);
            }
            let (old_start, old_lines, new_start, new_lines) = read_header(line);
            old_line = old_start;
            new_line = new_start;
            current = Some(Hunk {
                old_start,
                old_lines,
                new_start,
                new_lines,
                lines: Vec::new(),
            });
            continue;
        }
        let hunk = match current.as_mut() {
            Some(hunk) => hunk,
            None => continue,
        };
        if line.starts_with('+') {
            hunk.lines.push(HunkLine {
                kind: HunkLineKind::Added,
                text: line[1..].to_string(),
                old_line: None,
                new_line: Some(new_line),
            });
            new_line += 1;
        } else if line.starts_with('-') {
            hunk.lines.push(HunkLine {
                kind: HunkLineKind::Removed,
                text: line[1..].to_string(),
                old_line: Some(old_line),
                new_line: None,
            });
            old_line += 1;
        } else if line.starts_with(' ') {
            hunk.lines.push(HunkLine {
                kind: HunkLineKind::Context,
                text: line[1..].to_string(),
                old_line: Some(old_line),
                new_line: Some(new_line),
            });
            old_line += 1;
            new_line += 1;
        }
    }
    if let Some(hunk) = current.take() {
        hunks.push(hunk);
    }
    hunks
}

/// read_header reads "@@ -12,3 +14,5 @@" into the two sides.
fn read_header(line: &str) -> (u64, u64, u64, u64) {
    let mut old = (0, 0);
    let mut new = (0, 0);
    for piece in line.split_whitespace() {
        if let Some(rest) = piece.strip_prefix('-') {
            old = read_range(rest);
        } else if let Some(rest) = piece.strip_prefix('+') {
            new = read_range(rest);
        }
    }
    (old.0, old.1, new.0, new.1)
}

/// read_range reads "12,3" or "12" into a start and a count.
fn read_range(text: &str) -> (u64, u64) {
    let text = text.trim_end_matches("@@");
    match text.split_once(',') {
        Some((start, count)) => (
            start.trim().parse().unwrap_or(0),
            count.trim().parse().unwrap_or(0),
        ),
        None => (text.trim().parse().unwrap_or(0), 1),
    }
}

/// parse_files reads a diff of a whole tree: the files it touched, and the
/// hunks of each.
///
/// The name of the file is read from the header of its own diff, so a path
/// with a space in it stays one path.
pub fn parse_files(output: &str) -> Vec<FileDiff> {
    let mut files: Vec<FileDiff> = Vec::new();
    let mut path = String::new();
    let mut hunks: Vec<Hunk> = Vec::new();
    let mut current: Option<Hunk> = None;
    let mut old_line: u64 = 0;
    let mut new_line: u64 = 0;
    for line in output.lines() {
        if line.starts_with("diff --git ") {
            // The file that was being read is closed, and the next one
            // begins. The last hunk of the file belongs to that file.
            if let Some(hunk) = current.take() {
                hunks.push(hunk);
            }
            if !path.is_empty() {
                files.push(FileDiff {
                    path: path.clone(),
                    hunks: std::mem::take(&mut hunks),
                });
            }
            path = String::new();
            continue;
        }
        if line.starts_with("+++ ") {
            // The name the file has now.
            path = line[4..].trim_start_matches("b/").to_string();
            continue;
        }
        if line.starts_with("--- ") {
            // A file that is gone has no new name; the old one is its name.
            if path.is_empty() {
                path = line[4..].trim_start_matches("a/").to_string();
            }
            continue;
        }
        if line.starts_with("@@") {
            if let Some(hunk) = current.take() {
                hunks.push(hunk);
            }
            let (old_start, old_lines, new_start, new_lines) = read_header(line);
            old_line = old_start;
            new_line = new_start;
            current = Some(Hunk {
                old_start,
                old_lines,
                new_start,
                new_lines,
                lines: Vec::new(),
            });
            continue;
        }
        let hunk = match current.as_mut() {
            Some(hunk) => hunk,
            None => continue,
        };
        if line.starts_with('+') {
            hunk.lines.push(HunkLine {
                kind: HunkLineKind::Added,
                text: line[1..].to_string(),
                old_line: None,
                new_line: Some(new_line),
            });
            new_line += 1;
        } else if line.starts_with('-') {
            hunk.lines.push(HunkLine {
                kind: HunkLineKind::Removed,
                text: line[1..].to_string(),
                old_line: Some(old_line),
                new_line: None,
            });
            old_line += 1;
        } else if line.starts_with(' ') {
            hunk.lines.push(HunkLine {
                kind: HunkLineKind::Context,
                text: line[1..].to_string(),
                old_line: Some(old_line),
                new_line: Some(new_line),
            });
            old_line += 1;
            new_line += 1;
        }
    }
    if let Some(hunk) = current.take() {
        hunks.push(hunk);
    }
    if !path.is_empty() {
        files.push(FileDiff { path, hunks });
    }
    files
}

/// name answers the comparison as a person reads it.
pub fn comparison_name(comparison: Comparison) -> &'static str {
    comparison.name()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hunk_says_where_it_is_on_both_sides() {
        let diff = "@@ -10,3 +10,4 @@\n context\n-removed\n+added\n+more\n";
        let hunks = parse(diff);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].old_start, 10);
        assert_eq!(hunks[0].old_lines, 3);
        assert_eq!(hunks[0].new_start, 10);
        assert_eq!(hunks[0].new_lines, 4);
    }

    #[test]
    fn the_lines_of_a_hunk_know_what_they_are() {
        let diff = "@@ -1,2 +1,2 @@\n context\n-removed\n+added\n";
        let hunks = parse(diff);
        let lines = &hunks[0].lines;
        assert_eq!(lines[0].kind, HunkLineKind::Context);
        assert_eq!(lines[1].kind, HunkLineKind::Removed);
        assert_eq!(lines[1].text, "removed");
        // The context line took the first line of each side, so the
        // removed line is the second of the old side.
        assert_eq!(lines[1].old_line, Some(2));
        assert_eq!(lines[1].new_line, None);
        assert_eq!(lines[2].kind, HunkLineKind::Added);
        assert_eq!(lines[2].new_line, Some(2));
    }

    #[test]
    fn several_hunks_are_several_hunks() {
        let diff = "@@ -1,1 +1,1 @@\n-a\n+b\n@@ -20,1 +20,1 @@\n-c\n+d\n";
        let hunks = parse(diff);
        assert_eq!(hunks.len(), 2);
        assert_eq!(hunks[1].old_start, 20);
    }

    #[test]
    fn a_diff_with_no_hunks_has_no_hunks() {
        assert!(parse("diff --git a/x b/x\n").is_empty());
    }

    #[test]
    fn a_diff_of_a_tree_is_a_list_of_files() {
        let diff = "diff --git a/one.txt b/one.txt\n--- a/one.txt\n+++ b/one.txt\n@@ -1 +1 @@\n-a\n+b\ndiff --git a/two.txt b/two.txt\n--- a/two.txt\n+++ b/two.txt\n@@ -5 +5 @@\n-c\n+d\n";
        let files = parse_files(diff);
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].path, "one.txt");
        assert_eq!(files[1].path, "two.txt");
        assert_eq!(files[1].hunks[0].old_start, 5);
    }

    #[test]
    fn a_path_with_spaces_stays_one_path() {
        let diff = "diff --git a/a file.txt b/a file.txt\n--- a/a file.txt\n+++ b/a file.txt\n@@ -1 +1 @@\n-a\n+b\n";
        let files = parse_files(diff);
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "a file.txt");
    }

    #[test]
    fn a_file_that_is_gone_keeps_its_name() {
        let diff = "diff --git a/old.txt b/old.txt\n--- a/old.txt\n@@ -1 +0,0 @@\n-a\n";
        let files = parse_files(diff);
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "old.txt");
    }
}
