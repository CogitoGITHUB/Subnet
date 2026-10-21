// One job: the branches — the local branches, their upstream, and how far
// they are from it.
//
// The counts come from the refs that are here. Nothing is fetched, so a
// branch whose upstream ref is missing is UNKNOWN: it is never reported as
// up to date, and it is never reported as behind either.

use crate::model::Divergence;

/// Branch is one local branch: where it points, what its upstream is, and
/// how far it is from it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Branch {
    pub name: String,
    pub head: String,
    pub upstream: String,
    pub divergence: Divergence,
    pub is_head: bool,
}

/// parse reads the branches of the for-each-ref format: the name, the
/// commit, the upstream, the track, and whether it is the head, each field
/// its own, the whole record ending in a NUL.
pub fn parse(output: &str) -> Vec<Branch> {
    let fields: Vec<&str> = output.split('\0').collect();
    let mut branches: Vec<Branch> = Vec::new();
    let mut at = 0;
    while at + 4 < fields.len() {
        let name = fields[at];
        if name.is_empty() {
            at += 1;
            continue;
        }
        let head = fields[at + 1].to_string();
        let upstream = fields[at + 2].to_string();
        let track = fields[at + 3].to_string();
        let is_head = fields[at + 4].trim() == "*";
        let divergence = read_track(&upstream, &track);
        branches.push(Branch {
            name: name.to_string(),
            head,
            upstream,
            divergence,
            is_head,
        });
        at += 5;
    }
    branches
}

/// read_track reads what Git wrote about the distance: "[ahead 2, behind 1]"
/// or "" when there is nothing to say.
fn read_track(upstream: &str, track: &str) -> Divergence {
    if upstream.is_empty() {
        return Divergence::Unknown;
    }
    let inside = track.trim().trim_start_matches('[').trim_end_matches(']');
    if inside.is_empty() {
        return Divergence::UpToDate;
    }
    let mut ahead: u64 = 0;
    let mut behind: u64 = 0;
    for piece in inside.split(", ") {
        let piece = piece.trim();
        if let Some(number) = piece.strip_prefix("ahead ") {
            ahead = number.parse().unwrap_or(0);
        } else if let Some(number) = piece.strip_prefix("behind ") {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_branch_without_an_upstream_is_unknown() {
        let branches = parse("main\0abcdef\0\0\0\0");
        assert_eq!(branches.len(), 1);
        assert_eq!(branches[0].name, "main");
        assert_eq!(branches[0].divergence, Divergence::Unknown);
    }

    #[test]
    fn a_branch_ahead_of_its_upstream_is_ahead() {
        let branches = parse("main\0abcdef\0origin/main\0[ahead 2]\0*\0");
        assert_eq!(branches[0].divergence, Divergence::Ahead(2));
        assert!(branches[0].is_head);
    }

    #[test]
    fn a_branch_behind_its_upstream_is_behind() {
        let branches = parse("main\0abcdef\0origin/main\0[behind 3]\0 \0");
        assert_eq!(branches[0].divergence, Divergence::Behind(3));
    }

    #[test]
    fn a_branch_on_both_sides_is_diverged() {
        let branches = parse("main\0abcdef\0origin/main\0[ahead 1, behind 4]\0 \0");
        assert_eq!(branches[0].divergence, Divergence::Diverged { ahead: 1, behind: 4 });
    }

    #[test]
    fn a_branch_in_step_with_its_upstream_is_up_to_date() {
        let branches = parse("main\0abcdef\0origin/main\0\0 \0");
        assert_eq!(branches[0].divergence, Divergence::UpToDate);
    }
}
