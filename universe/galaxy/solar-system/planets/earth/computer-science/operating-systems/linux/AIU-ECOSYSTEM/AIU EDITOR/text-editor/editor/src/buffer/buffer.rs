// One job: the text state — the bytes, the lines, the offsets.
// The buffer holds the text of a file plus the edits that are not saved
// yet. It is the hot path's state: the meaning side never holds the text.

/// Buffer is one text: the whole text, the lines it is made of, and the
/// byte offset where each line starts.
pub struct Buffer {
    text: String,
    lines: Vec<String>,
    offsets: Vec<usize>,
}

/// new_buffer makes a buffer from text: the lines are split on the
/// newline, and every line's offset is counted in bytes.
pub fn new_buffer(text: &str) -> Buffer {
    let mut lines: Vec<String> = Vec::new();
    let mut offsets: Vec<usize> = Vec::new();
    let mut offset = 0usize;
    for line in text.split('\n') {
        lines.push(line.to_string());
        offsets.push(offset);
        offset += line.len() + 1;
    }
    Buffer {
        text: text.to_string(),
        lines,
        offsets,
    }
}

/// append puts more text at the end of the buffer and answers the new
/// byte length of the text.
pub fn append(buffer: &mut Buffer, more: &str) -> usize {
    let grown = format!("{}{}", buffer.text, more);
    *buffer = new_buffer(&grown);
    buffer.text.len()
}

/// insert_at puts more text into the buffer at a byte offset, and
/// answers the new byte length of the text. An offset past the end of
/// the text puts the text at the end, so an edit is never lost.
pub fn insert_at(buffer: &mut Buffer, at: usize, more: &str) -> usize {
    let at = at.min(buffer.text.len());
    let mut grown = String::new();
    grown.push_str(&buffer.text[..at]);
    grown.push_str(more);
    grown.push_str(&buffer.text[at..]);
    *buffer = new_buffer(&grown);
    buffer.text.len()
}

/// delete_at takes text out of the buffer at a byte offset, and answers
/// the new byte length of the text. The count is the number of bytes
/// taken, and the text past the end of the buffer is not taken.
pub fn delete_at(buffer: &mut Buffer, at: usize, count: usize) -> usize {
    let at = at.min(buffer.text.len());
    let to = at.saturating_add(count).min(buffer.text.len());
    let mut grown = String::new();
    grown.push_str(&buffer.text[..at]);
    grown.push_str(&buffer.text[to..]);
    *buffer = new_buffer(&grown);
    buffer.text.len()
}

/// text_range answers the text between two byte offsets. The offsets
/// are put in order, so the answer is the same whichever way they come.
pub fn text_range(buffer: &Buffer, from: usize, to: usize) -> String {
    let low = from.min(to).min(buffer.text.len());
    let high = to.max(from).min(buffer.text.len());
    buffer.text[low..high].to_string()
}

/// move_point answers where the point goes when it moves: up or down a
/// line, or left or right a character. A line move keeps the column when
/// the line is long enough, and a character move stops at the end of the
/// text. The answer is the new byte offset of the point.
pub fn move_point(buffer: &Buffer, at: usize, direction: &str) -> usize {
    let at = at.min(buffer.text.len());
    match direction {
        "left" => {
            if at == 0 {
                0
            } else {
                let mut back = at - 1;
                while back > 0 && !buffer.text.is_char_boundary(back) {
                    back -= 1;
                }
                back
            }
        }
        "right" => {
            let mut forward = at;
            while forward < buffer.text.len() && !buffer.text.is_char_boundary(forward) {
                forward += 1;
            }
            if forward < buffer.text.len() {
                forward += 1;
            }
            forward
        }
        "up" | "down" => {
            let line = line_of(buffer, at);
            let column = at.saturating_sub(line_offset(buffer, line).unwrap_or(0));
            let target = if direction == "up" {
                if line == 0 {
                    return at;
                }
                line - 1
            } else {
                if line + 1 >= buffer.lines.len() {
                    return at;
                }
                line + 1
            };
            let start = line_offset(buffer, target).unwrap_or(0);
            let length = buffer.lines[target].len();
            (start + column).min(start + length)
        }
        "home" => line_offset(buffer, line_of(buffer, at)).unwrap_or(0),
        "end" => {
            let line = line_of(buffer, at);
            line_offset(buffer, line).unwrap_or(0) + buffer.lines[line].len()
        }
        _ => at,
    }
}

/// line_of answers the number of the line the point is on, counting from
/// zero.
pub fn line_of(buffer: &Buffer, at: usize) -> usize {
    let at = at.min(buffer.text.len());
    let mut number = 0usize;
    for (index, offset) in buffer.offsets.iter().enumerate() {
        if *offset <= at {
            number = index;
        } else {
            break;
        }
    }
    number
}

/// text_of answers the whole text of the buffer.
pub fn text_of(buffer: &Buffer) -> &str {
    &buffer.text
}

/// line_count answers how many lines the buffer holds.
pub fn line_count(buffer: &Buffer) -> usize {
    buffer.lines.len()
}

/// byte_len answers the length of the text in bytes.
pub fn byte_len(buffer: &Buffer) -> usize {
    buffer.text.len()
}

/// line_offset answers the byte offset where the line at the index starts.
pub fn line_offset(buffer: &Buffer, index: usize) -> Option<usize> {
    buffer.offsets.get(index).copied()
}
