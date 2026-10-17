//! One job: offset to line/column and back, one pair of functions.
//! Registered in plan/package-tree.org (text/positions.rs).
//!
//! The rule from syntax/first-slice-freeze.org, rule F: **offsets are counted
//! in bytes, columns are counted in characters**. Both directions are here, so
//! no other file converts a position in its own way.

use crate::buffer::Buffer;

/// A place in a file: a 1-based line and a 1-based column of characters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LineCol {
    pub line: usize,
    pub column: usize,
}

/// The byte offset of a line and character column.
///
/// A column past the end of the line lands at the end of that line instead of
/// running into the next one, so a caller asking for "the end of line 4" gets
/// the end of line 4.
pub fn line_col_to_offset(buffer: &Buffer, line: usize, column: usize) -> usize {
    let start = buffer.line_start(line);
    let end = buffer.line_end(line);
    let bytes = buffer.slice(start, end);
    if column <= 1 {
        return start;
    }
    let mut remaining = column - 1;
    let mut offset = start;
    for b in bytes {
        if remaining == 0 {
            break;
        }
        // step by whole characters: a multi-byte character counts as one column
        let width = utf8_char_width(*b);
        offset += width;
        remaining -= 1;
    }
    offset.min(end)
}

/// The line and character column of a byte offset. An offset past the end of
/// the file lands on the last line, at its last column.
pub fn offset_to_line_col(buffer: &Buffer, offset: usize) -> LineCol {
    let line = buffer.line_at(offset);
    let start = buffer.line_start(line);
    let clamped = offset.min(buffer.bytes().len()).max(start);
    let mut column = 1usize;
    let bytes = buffer.slice(start, clamped);
    let mut i = 0usize;
    while i < bytes.len() {
        i += utf8_char_width(bytes[i]);
        column += 1;
    }
    LineCol { line, column }
}

/// How many bytes the character starting with this byte takes. A continuation
/// byte (10xxxxxx) cannot start a character, so it is one byte wide here; the
/// caller only ever steps on a character boundary.
fn utf8_char_width(first: u8) -> usize {
    if first < 0x80 {
        1
    } else if first >> 5 == 0b110 {
        2
    } else if first >> 4 == 0b1110 {
        3
    } else if first >> 3 == 0b11110 {
        4
    } else {
        1
    }
}