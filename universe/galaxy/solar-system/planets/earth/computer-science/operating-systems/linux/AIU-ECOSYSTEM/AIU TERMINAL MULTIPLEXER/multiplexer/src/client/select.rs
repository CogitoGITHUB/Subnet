// One job: the selection — the point, the mark, and the text between
// them.
//
// The selection is an overlay on the visual mode, not a mode of its own
// in the pane: the keys move a point over the visible text, one key sets
// the mark, and the region is the text between the mark and the point.
//
// The candidates are the visible text only: a line that has scrolled
// out of the pane cannot be picked, because it cannot be seen.
//
// The anchor is a mark and not a second point: the mark is where the
// point stood when the owner set it, and the region runs from the mark
// to the point, whichever of the two comes first.

/// Selection is where the point stands and where the marks stand.
///
/// The marks live in a ring: a mark is pushed and popped, and the
/// newest mark is the anchor of the region. Without a mark there is no
/// region: nothing is selected yet.
#[derive(Clone, Debug, Default)]
pub struct Selection {
    /// point is the line and the column the point stands on.
    pub point: (usize, usize),
    /// marks are the anchors, newest last.
    pub marks: Vec<(usize, usize)>,
}

impl Selection {
    /// new answers a selection with the point at the first line.
    pub fn new() -> Selection {
        Selection {
            point: (0, 0),
            marks: Vec::new(),
        }
    }

    /// left moves the point one character to the left.
    pub fn left(&mut self, lines: &[String]) {
        let (line, column) = self.point;
        if column > 0 {
            self.point = (line, column - 1);
            return;
        }
        if line > 0 {
            let above = lines.get(line - 1).map(|text| text.chars().count()).unwrap_or(0);
            self.point = (line - 1, above);
        }
    }

    /// right moves the point one character to the right.
    pub fn right(&mut self, lines: &[String]) {
        let (line, column) = self.point;
        let width = lines.get(line).map(|text| text.chars().count()).unwrap_or(0);
        if column < width {
            self.point = (line, column + 1);
            return;
        }
        if line + 1 < lines.len() {
            self.point = (line + 1, 0);
        }
    }

    /// up moves the point one line up, and keeps the column when the line
    /// is long enough.
    pub fn up(&mut self, lines: &[String]) {
        let (line, column) = self.point;
        if line > 0 {
            let above = lines.get(line - 1).map(|text| text.chars().count()).unwrap_or(0);
            self.point = (line - 1, column.min(above));
        }
    }

    /// down moves the point one line down, and keeps the column when the
    /// line is long enough.
    pub fn down(&mut self, lines: &[String]) {
        let (line, column) = self.point;
        if line + 1 < lines.len() {
            let below = lines.get(line + 1).map(|text| text.chars().count()).unwrap_or(0);
            self.point = (line + 1, column.min(below));
        }
    }

    /// word_left moves the point to the start of the word before it.
    pub fn word_left(&mut self, lines: &[String]) {
        let (line, column) = self.point;
        let text = lines.get(line).cloned().unwrap_or_default();
        let characters: Vec<char> = text.chars().collect();
        let mut at = column.min(characters.len());
        while at > 0 && characters[at - 1].is_whitespace() {
            at -= 1;
        }
        while at > 0 && !characters[at - 1].is_whitespace() {
            at -= 1;
        }
        self.point = (line, at);
    }

    /// word_right moves the point to the start of the next word.
    pub fn word_right(&mut self, lines: &[String]) {
        let (line, column) = self.point;
        let text = lines.get(line).cloned().unwrap_or_default();
        let characters: Vec<char> = text.chars().collect();
        let mut at = column.min(characters.len());
        while at < characters.len() && !characters[at].is_whitespace() {
            at += 1;
        }
        while at < characters.len() && characters[at].is_whitespace() {
            at += 1;
        }
        self.point = (line, at);
    }

    /// set_mark pushes the mark where the point stands onto the ring.
    pub fn set_mark(&mut self) {
        self.marks.push(self.point);
    }

    /// pop_mark takes the newest mark off the ring, and the anchor that
    /// stands is the one below it.
    pub fn pop_mark(&mut self) {
        self.marks.pop();
    }

    /// mark answers the anchor of the region: the newest mark, when there
    /// is one.
    pub fn mark(&self) -> Option<(usize, usize)> {
        self.marks.last().copied()
    }

    /// region answers the text between the mark and the point, whichever
    /// of the two comes first. Without a mark there is no region.
    pub fn region(&self, lines: &[String]) -> String {
        let mark = match self.mark() {
            Some(mark) => mark,
            None => return String::new(),
        };
        let (from, to) = if mark <= self.point {
            (mark, self.point)
        } else {
            (self.point, mark)
        };
        let mut text = String::new();
        for line in from.0..=to.0 {
            if line >= lines.len() {
                break;
            }
            let characters: Vec<char> = lines[line].chars().collect();
            let start = if line == from.0 { from.1.min(characters.len()) } else { 0 };
            let end = if line == to.0 { to.1.min(characters.len()) } else { characters.len() };
            if start < end {
                text.push_str(&characters[start..end].iter().collect::<String>());
            }
            if line != to.0 {
                text.push('\n');
            }
        }
        text
    }

    /// line_text answers the text of the line the point stands on.
    pub fn line_text(&self, lines: &[String]) -> String {
        lines.get(self.point.0).cloned().unwrap_or_default()
    }

    /// marked answers the lines with the region marked: the text between
    /// the mark and the point is shown in reverse video, and the rest of
    /// the lines are as they were.
    ///
    /// The mark is drawn too, so the owner can see where the region
    /// begins.
    pub fn marked(&self, lines: &[String]) -> Vec<String> {
        let mark = match self.mark() {
            Some(mark) => mark,
            None => return lines.to_vec(),
        };
        let (from, to) = if mark <= self.point {
            (mark, self.point)
        } else {
            (self.point, mark)
        };
        let mut marked: Vec<String> = Vec::new();
        for (at, text) in lines.iter().enumerate() {
            if at < from.0 || at > to.0 {
                marked.push(text.clone());
                continue;
            }
            let characters: Vec<char> = text.chars().collect();
            let start = if at == from.0 { from.1.min(characters.len()) } else { 0 };
            let end = if at == to.0 { to.1.min(characters.len()) } else { characters.len() };
            if end <= start {
                marked.push(text.clone());
                continue;
            }
            let mut line = String::new();
            line.push_str(&characters[..start].iter().collect::<String>());
            line.push_str("\x1b[7m");
            line.push_str(&characters[start..end].iter().collect::<String>());
            line.push_str("\x1b[0m");
            line.push_str(&characters[end..].iter().collect::<String>());
            marked.push(line);
        }
        marked
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn the_lines() -> Vec<String> {
        vec![
            "the first line".to_string(),
            "the second word here".to_string(),
            "the third".to_string(),
        ]
    }

    #[test]
    fn the_point_moves_over_the_visible_text() {
        let lines = the_lines();
        let mut selection = Selection::new();
        selection.right(&lines);
        selection.right(&lines);
        assert_eq!(selection.point, (0, 2));
        selection.down(&lines);
        assert_eq!(selection.point, (1, 2));
        selection.left(&lines);
        assert_eq!(selection.point, (1, 1));
        selection.up(&lines);
        assert_eq!(selection.point, (0, 1));
    }

    #[test]
    fn the_point_moves_by_word() {
        let lines = the_lines();
        let mut selection = Selection::new();
        selection.word_right(&lines);
        assert_eq!(selection.point, (0, 4));
        selection.word_left(&lines);
        assert_eq!(selection.point, (0, 0));
    }

    #[test]
    fn the_region_runs_from_the_mark_to_the_point() {
        let lines = the_lines();
        let mut selection = Selection::new();
        selection.right(&lines);
        selection.right(&lines);
        selection.set_mark();
        selection.down(&lines);
        selection.right(&lines);
        selection.right(&lines);
        assert_eq!(selection.region(&lines), "e first line\nthe ");
    }

    #[test]
    fn the_region_runs_backwards_too() {
        let lines = the_lines();
        let mut selection = Selection::new();
        selection.right(&lines);
        selection.right(&lines);
        selection.set_mark();
        selection.left(&lines);
        selection.left(&lines);
        assert_eq!(selection.region(&lines), "th");
    }

    #[test]
    fn the_marks_are_a_ring() {
        let lines = the_lines();
        let mut selection = Selection::new();
        selection.right(&lines);
        selection.set_mark();
        selection.right(&lines);
        selection.set_mark();
        assert_eq!(selection.mark(), Some((0, 2)));
        selection.pop_mark();
        assert_eq!(selection.mark(), Some((0, 1)));
        selection.pop_mark();
        assert_eq!(selection.mark(), None);
    }

    #[test]
    fn without_a_mark_there_is_no_region() {
        let lines = the_lines();
        let selection = Selection::new();
        assert_eq!(selection.region(&lines), "");
    }

    #[test]
    fn the_marked_lines_show_the_region_in_reverse_video() {
        let lines = the_lines();
        let mut selection = Selection::new();
        selection.right(&lines);
        selection.set_mark();
        selection.right(&lines);
        let marked = selection.marked(&lines);
        assert!(marked[0].contains("\x1b[7m"), "the region is marked: {:?}", marked);
        assert!(marked[1].contains("\x1b[7m") == false, "the other lines are not: {:?}", marked);
    }
}
