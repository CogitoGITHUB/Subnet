// One job: the geometry — where each pane sits on the terminal.
//
// The drawing and the sizes the programs get are ONE geometry: the screen
// draws the panes where this says, and the holder gives every program the
// size of the place it is drawn in. Two geometries would drift, and a
// program would redraw for a size it does not have.

/// Rect is one pane's place on the terminal: where it starts and how big it
/// is. The rows and the columns are 1-based, the way the terminal counts.
pub struct Rect {
    pub top: u16,
    pub left: u16,
    pub rows: u16,
    pub cols: u16,
}

/// MIN_COLS is the smallest width a pane is drawn at: a pane narrower than
/// this cannot show a word.
const MIN_COLS: u16 = 6;
/// MIN_ROWS is the smallest height a pane is drawn at.
const MIN_ROWS: u16 = 3;

/// rects answers where each pane sits, in the order the panes are given.
/// The direction says whether they stand side by side or one above the
/// other, and the weight says how much of the space each one wants.
pub fn rects(
    direction: &str,
    weights: &[u16],
    cols: u16,
    rows: u16,
    top: u16,
) -> Vec<Rect> {
    let total: u32 = weights.iter().map(|weight| (*weight).max(1) as u32).sum();
    let total = total.max(1);
    let mut held: Vec<Rect> = Vec::new();
    if direction == "column" {
        let mut top = top;
        let mut used: u32 = 0;
        for (at, weight) in weights.iter().enumerate() {
            let weight = (*weight).max(1) as u32;
            let height = if at + 1 == weights.len() {
                (rows as u32).saturating_sub(used)
            } else {
                (rows as u32 * weight) / total
            };
            used += height;
            let height = height.max(MIN_ROWS as u32) as u16;
            held.push(Rect {
                top,
                left: 1,
                rows: height,
                cols,
            });
            top += height;
        }
    } else {
        let mut left: u16 = 1;
        let mut used: u32 = 0;
        for (at, weight) in weights.iter().enumerate() {
            let weight = (*weight).max(1) as u32;
            let width = if at + 1 == weights.len() {
                (cols as u32).saturating_sub(used)
            } else {
                (cols as u32 * weight) / total
            };
            used += width;
            let width = width.max(MIN_COLS as u32) as u16;
            held.push(Rect {
                top,
                left,
                rows,
                cols: width,
            });
            left += width;
        }
    }
    held
}

#[cfg(test)]
mod tests {
    use super::*;

    /// two_weighed answers the places of two panes that want one and three.
    fn two_weighed() -> Vec<Rect> {
        rects("row", &[1, 3], 80, 24, 1)
    }

    #[test]
    fn the_weight_divides_the_space() {
        let held = two_weighed();
        assert_eq!(held.len(), 2);
        assert_eq!(held[0].cols, 20);
        assert_eq!(held[1].cols, 60);
    }

    #[test]
    fn the_last_pane_takes_what_is_left() {
        let held = two_weighed();
        assert_eq!(held[0].left, 1);
        assert_eq!(held[1].left, 21);
    }

    #[test]
    fn the_column_direction_stacks_the_panes() {
        let held = rects("column", &[1, 3], 80, 24, 1);
        assert_eq!(held[0].rows, 6);
        assert_eq!(held[1].rows, 18);
        assert_eq!(held[1].top, 7);
    }

    #[test]
    fn a_pane_is_never_too_narrow_to_read() {
        let held = rects("row", &[1, 1], 4, 24, 1);
        assert!(held[0].cols >= MIN_COLS);
        assert!(held[1].cols >= MIN_COLS);
    }
}
