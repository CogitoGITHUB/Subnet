// One job: the drawing of the dashboard — the pieces are placed on a
// screen and the screen is written out, one line per row. The meaning
// side says what each piece shows and where it goes; this file only
// draws what it is told (rule 09).
//
// The placement is free: a piece may sit on any of the four edges or
// float in the middle, and several pieces may share an edge. The order
// says which comes first.
//
// The size of a piece is the WIDTH it takes, in columns, and the piece is
// never cut: a piece whose text needs more room than its size says gets
// the room it needs. The height of a piece is the number of lines of its
// text, so the same piece fits any edge.
//
// The rules of the placement, once:
//   - the top pieces take their rows from the top and the bottom pieces
//     take their rows from the bottom, in the order they are placed;
//   - the left pieces take their columns from the left and the right
//     pieces from the right, the same order;
//   - a top or a bottom piece owns the whole width; a left or a right
//     piece owns only the rows between the top and the bottom bands;
//   - a floating piece owns lines of the middle, and the middle is what
//     is left once the bands are taken.

/// Piece is one placeable piece: its name, the edge it sits on, the
/// width it takes, the order it is placed in and the lines of text it
/// shows.
pub struct Piece {
    pub name: String,
    pub edge: String,
    pub size: usize,
    pub order: usize,
    pub content: Vec<String>,
}

/// parse_pieces reads the pieces of a request. The pieces arrive one by
/// one, each in its own argument, and the fields of a piece are
/// separated by a tab: the name, the edge, the size, the order, and
/// then the text, which may hold more than one line.
pub fn parse_pieces(entries: &[(String, String)], count: usize) -> Vec<Piece> {
    let mut pieces: Vec<Piece> = Vec::new();
    for index in 0..count {
        let key = format!("piece{}", index);
        let raw = match value_of(entries, &key) {
            Some(value) => value,
            None => continue,
        };
        let mut fields = raw.splitn(5, '\t');
        let name = fields.next().unwrap_or("").to_string();
        let edge = fields.next().unwrap_or("").to_string();
        let size = fields
            .next()
            .and_then(|value| value.trim().parse::<usize>().ok())
            .unwrap_or(1);
        let order = fields
            .next()
            .and_then(|value| value.trim().parse::<usize>().ok())
            .unwrap_or(0);
        let text = fields.next().unwrap_or("");
        let content: Vec<String> = text.split('\n').map(|line| line.to_string()).collect();
        pieces.push(Piece {
            name,
            edge,
            size,
            order,
            content,
        });
    }
    pieces
}

/// value_of answers one argument of the entries, and answers nothing when
/// the entries do not carry it.
fn value_of(entries: &[(String, String)], key: &str) -> Option<String> {
    for (name, value) in entries {
        if name == key {
            return Some(value.clone());
        }
    }
    None
}

/// width_of answers the width a piece really takes: the width it asks
/// for, or the width its text needs when that is more. A piece is never
/// cut, so the same piece fits on any edge.
pub fn width_of(piece: &Piece) -> usize {
    let needed = piece
        .content
        .iter()
        .map(|line| line.chars().count())
        .max()
        .unwrap_or(0);
    piece.size.max(needed)
}

/// height_of answers the number of rows a piece takes: one for each line
/// of its text, and never less than one.
pub fn height_of(piece: &Piece) -> usize {
    piece.content.len().max(1)
}

/// draw places the pieces on a screen of the given size and answers the
/// screen, one line per row. The screen is as tall as the pieces need
/// it, and never taller than the size given.
pub fn draw(pieces: &[Piece], width: usize, height: usize) -> Vec<String> {
    let mut ordered: Vec<&Piece> = pieces.iter().collect();
    ordered.sort_by_key(|piece| piece.order);

    let mut top_height = 0usize;
    let mut bottom_height = 0usize;
    let mut left_width = 0usize;
    let mut right_width = 0usize;
    for piece in &ordered {
        match piece.edge.as_str() {
            "top" => top_height += height_of(piece),
            "bottom" => bottom_height += height_of(piece),
            "left" => left_width += width_of(piece),
            "right" => right_width += width_of(piece),
            _ => {}
        }
    }
    if top_height + bottom_height > height {
        top_height = height;
        bottom_height = 0;
    }
    if left_width + right_width > width {
        left_width = width;
        right_width = 0;
    }

    // The screen is as tall as the pieces need it, and never taller than
    // the size given: a piece is never cut, in the width or in the height.
    let mut middle_needed = 0usize;
    for piece in &ordered {
        let edge = piece.edge.as_str();
        if edge != "top" && edge != "bottom" {
            let needed = height_of(piece);
            if needed > middle_needed {
                middle_needed = needed;
            }
        }
    }
    let middle = middle_needed.max(height.saturating_sub(top_height + bottom_height));
    let total = top_height + middle + bottom_height;

    let mut screen: Vec<Vec<char>> = Vec::new();
    for _ in 0..total {
        screen.push(vec![' '; width]);
    }
    let middle_start = top_height;
    let middle_end = screen.len() - bottom_height;

    let mut top_at = 0usize;
    let mut bottom_at = screen.len();
    let mut left_at = 0usize;
    let mut right_at = width;
    let mut floating_at = middle_start;

    for piece in ordered {
        match piece.edge.as_str() {
            "top" => {
                place_rows(&mut screen, piece, top_at, 0, width);
                top_at += height_of(piece);
            }
            "bottom" => {
                bottom_at = bottom_at.saturating_sub(height_of(piece));
                place_rows(&mut screen, piece, bottom_at, 0, width);
            }
            "left" => {
                let at = left_at;
                place_columns(&mut screen, piece, at, middle_start, middle_end);
                left_at += width_of(piece);
            }
            "right" => {
                let at = right_at.saturating_sub(width_of(piece));
                place_columns(&mut screen, piece, at, middle_start, middle_end);
                right_at = at;
            }
            _ => {
                place_rows(&mut screen, piece, floating_at, left_at, width);
                floating_at += height_of(piece);
            }
        }
    }

    screen
        .into_iter()
        .map(|row| row.into_iter().collect::<String>())
        .collect()
}

/// place_rows writes the text of a piece into its own rows, one line of
/// text per row, and the rest of the row stays blank.
fn place_rows(screen: &mut [Vec<char>], piece: &Piece, start: usize, from: usize, to: usize) {
    for (index, line) in piece.content.iter().enumerate() {
        let row = start + index;
        if row >= screen.len() {
            break;
        }
        write_text(&mut screen[row], line, from, to);
    }
}

/// place_columns writes the text of a piece into its own columns, one
/// line of text per row of the middle, and the rest of the columns stay
/// blank.
fn place_columns(
    screen: &mut [Vec<char>],
    piece: &Piece,
    start: usize,
    middle_start: usize,
    middle_end: usize,
) {
    for (index, line) in piece.content.iter().enumerate() {
        let row = middle_start + index;
        if row >= middle_end {
            break;
        }
        write_text(&mut screen[row], line, start, start + width_of(piece));
    }
}

/// write_text writes one line of text into the screen between two
/// columns, and the text that does not fit is cut.
fn write_text(row: &mut [char], text: &str, from: usize, to: usize) {
    let mut at = from;
    for character in text.chars() {
        if at >= to || at >= row.len() {
            break;
        }
        row[at] = character;
        at += 1;
    }
}
