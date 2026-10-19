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
