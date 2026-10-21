// One job: the history — the commits, what they said, and the files they
// touched.
//
// A commit is read, never checked out: opening one shows what it said and
// what it changed, and the working tree and the index are left alone.

use crate::model::Commit;

/// parse reads the history in the format the layer asks for: the fields of
/// a commit, each its own, and then the files it touched.
pub fn parse(output: &str) -> Vec<Commit> {
    let fields: Vec<&str> = output.split('\0').collect();
    let mut commits: Vec<Commit> = Vec::new();
    let mut at = 0;
    while at < fields.len() {
        // The name-status section starts with a newline, so the field that
        // holds the next commit carries it.
        if !is_commit_id(fields[at]) {
            at += 1;
            continue;
        }
        let id = fields[at].trim_start_matches('\n').to_string();
        let short = clean(fields.get(at + 1).copied().unwrap_or(""));
        let author = clean(fields.get(at + 2).copied().unwrap_or(""));
        let email = clean(fields.get(at + 3).copied().unwrap_or(""));
        let when = clean(fields.get(at + 4).copied().unwrap_or(""))
            .parse::<i64>()
            .unwrap_or(0);
        let date = clean(fields.get(at + 5).copied().unwrap_or(""));
        let summary = clean(fields.get(at + 6).copied().unwrap_or(""));
        at += 7;
        // The files come in pairs: the status and the name, until the next
        // commit begins.
        let mut files: Vec<String> = Vec::new();
        while at + 1 < fields.len() && !is_commit_id(fields[at]) {
            let status = clean(fields[at]);
            if status.is_empty() {
                at += 1;
                continue;
            }
            let path = clean(fields[at + 1]);
            if !path.is_empty() {
                files.push(path);
            }
            at += 2;
        }
        commits.push(Commit {
            id,
            short,
            author,
            email,
            when,
            date,
            summary,
            files,
        });
    }
    commits
}

/// is_commit_id answers whether a field is the start of a commit: forty
/// hexadecimal characters, with the newline of the section before it
/// allowed.
fn is_commit_id(field: &str) -> bool {
    let field = field.trim_start_matches('\n');
    field.len() == 40 && field.chars().all(|one| one.is_ascii_hexdigit())
}

/// clean answers a field without the newline that may start it.
fn clean(field: &str) -> String {
    field.trim_start_matches('\n').to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_commit_carries_what_it_said_and_what_it_touched() {
        let id = "0123456789abcdef0123456789abcdef01234567";
        let output = format!(
            "{}\0abc1234\0Shape\0shape@example.org\01700000000\02026-10-21T10:00:00Z\0the summary\0M\0file.txt\0\0",
            id
        );
        let commits = parse(&output);
        assert_eq!(commits.len(), 1);
        assert_eq!(commits[0].short, "abc1234");
        assert_eq!(commits[0].author, "Shape");
        assert_eq!(commits[0].summary, "the summary");
        assert_eq!(commits[0].files, vec!["file.txt".to_string()]);
    }

    #[test]
    fn two_commits_are_two_commits() {
        let one = "0123456789abcdef0123456789abcdef01234567";
        let two = "89abcdef0123456789abcdef0123456789abcdef";
        let output = format!(
            "{}\0a\0A\0a@b\01\02026-10-21T10:00:00Z\0first\0\0{}\0b\0B\0b@b\02\02026-10-21T11:00:00Z\0second\0\0",
            one, two
        );
        let commits = parse(&output);
        assert_eq!(commits.len(), 2);
        assert_eq!(commits[1].summary, "second");
    }
}
