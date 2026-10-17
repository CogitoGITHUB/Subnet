//! One job: the text state — bytes, lines, offsets.
//! Registered in plan/package-tree.org (text/buffer.rs).
//!
//! The buffer owns the file bytes and the line starts. Everything else reads
//! positions through it, so there is exactly one place that knows how a line
//! begins. Offsets are counted in **bytes** (syntax/first-slice-freeze.org,
//! rule F); a column is counted in characters and is derived in positions.rs.

/// The raw text of one file, plus where each line starts.
///
/// Line endings are kept exactly as they are: nothing is normalized, nothing
/// is re-wrapped. `starts` holds the byte offset of the first byte of each
/// line, so `starts[i]` is where line `i + 1` begins.
pub struct Buffer {
    bytes: Vec<u8>,
    starts: Vec<usize>,
}

impl Buffer {
    /// Build a buffer from the file's bytes. A trailing newline does not
    /// create an extra empty line, which is what a reader expects.
    pub fn new(bytes: Vec<u8>) -> Buffer {
        let mut starts = vec![0usize];
        for (i, b) in bytes.iter().enumerate() {
            if *b == b'\n' {
                starts.push(i + 1);
            }
        }
        if bytes.last() == Some(&b'\n') {
            starts.pop();
        }
        Buffer { bytes, starts }
    }

    /// Build from a `&str`. The bytes are UTF-8 by construction here; a file
    /// read from disk keeps whatever it had, byte for byte.
    pub fn from_text(text: &str) -> Buffer {
        Buffer::new(text.as_bytes().to_vec())
    }

    /// The bytes, exactly as they came in.
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    /// How many bytes the file has. Offsets in this package are byte offsets.
    pub fn len(&self) -> usize {
        self.bytes.len()
    }

    /// The bytes as text. Returns None only if the file is not valid UTF-8,
    /// which the caller must report rather than replace.
    pub fn as_str(&self) -> Option<&str> {
        std::str::from_utf8(&self.bytes).ok()
    }

    /// How many lines the file has. An empty file has zero lines.
    pub fn line_count(&self) -> usize {
        self.starts.len()
    }

    /// The byte offset where a 1-based line number starts. Line numbers past
    /// the end of the file return the end of the last line, so a caller never
    /// walks off the buffer.
    pub fn line_start(&self, line: usize) -> usize {
        if line == 0 || self.starts.is_empty() {
            return 0;
        }
        if line <= self.starts.len() {
            self.starts[line - 1]
        } else {
            self.bytes.len()
        }
    }

    /// The byte offset where a 1-based line number ends, not counting the line
    /// ending itself.
    pub fn line_end(&self, line: usize) -> usize {
        if line == 0 || line > self.starts.len() {
            return self.bytes.len();
        }
        let start = self.starts[line - 1];
        let next = if line < self.starts.len() {
            self.starts[line]
        } else {
            self.bytes.len()
        };
        // step back over \r\n or \n so the span is the text of the line
        let mut end = next;
        if end > start && self.bytes[end - 1] == b'\n' {
            end -= 1;
        }
        if end > start && self.bytes[end - 1] == b'\r' {
            end -= 1;
        }
        end
    }

    /// The text of one 1-based line, without its line ending.
    pub fn line_text(&self, line: usize) -> &str {
        let start = self.line_start(line);
        let end = self.line_end(line);
        std::str::from_utf8(&self.bytes[start..end]).unwrap_or("")
    }

    /// The 1-based line number a byte offset falls on. An offset at the end of
    /// the file belongs to the last line, never to a line that does not exist.
    pub fn line_at(&self, offset: usize) -> usize {
        let offset = offset.min(self.bytes.len());
        match self.starts.binary_search(&offset) {
            Ok(i) => i + 1,
            Err(i) => i,
        }
    }

    /// The bytes of one 1-based line, with its line ending kept.
    pub fn line_bytes(&self, line: usize) -> &[u8] {
        let start = self.line_start(line);
        let end = if line < self.starts.len() {
            self.starts[line]
        } else {
            self.bytes.len()
        };
        &self.bytes[start..end]
    }

    /// The bytes of a span, as they came in. This is what lets the tree print
    /// the file back byte for byte.
    pub fn slice(&self, start: usize, end: usize) -> &[u8] {
        let start = start.min(self.bytes.len());
        let end = end.min(self.bytes.len()).max(start);
        &self.bytes[start..end]
    }
}