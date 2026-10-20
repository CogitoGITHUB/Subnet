// One job: the reading of the keys — the bytes arrive, and the reader
// says which key they are and whether a second key follows. The
// blocking read and the escape disambiguation are the hot path's job
// (rule 09), and the meaning side never sees a raw byte.
//
// The reader never uses a timer of its own: the kitty keyboard
// protocol's flags are what tell a key apart, and the protocol asks the
// terminal to report the escape codes it would otherwise swallow. A
// lone escape is the escape key, and the next byte decides it.

#[path = "keys.rs"]
mod keys;

use std::io::Read;

/// Reader holds the bytes that have arrived and the place in them where
/// the next key starts. The reader is the state of the input, and the
/// state of the editor is elsewhere: the file and the journal.
pub struct Reader {
    buffer: Vec<u8>,
    at: usize,
}

/// new_reader makes a reader with nothing read yet.
pub fn new_reader() -> Reader {
    Reader {
        buffer: Vec::new(),
        at: 0,
    }
}

/// push puts bytes that arrived into the reader.
pub fn push(reader: &mut Reader, bytes: &[u8]) {
    reader.buffer.extend_from_slice(bytes);
}

/// next_key answers the next key in the reader, or nothing when the
/// reader holds no whole key yet. The bytes of the key are taken out of
/// the reader, so the next call starts after them.
pub fn next_key(reader: &mut Reader) -> Option<keys::Key> {
    let waiting: Vec<u8> = reader.buffer[reader.at..].to_vec();
    let key = keys::decode(&waiting)?;
    reader.at += key.length;
    if reader.at >= reader.buffer.len() {
        reader.buffer.clear();
        reader.at = 0;
    }
    Some(key)
}

/// pending answers how many bytes the reader holds that no key has
/// taken yet.
pub fn pending(reader: &Reader) -> usize {
    reader.buffer.len() - reader.at
}

/// read_more reads more bytes from a source and puts them into the
/// reader. It answers how many bytes came. A source that is finished
/// answers nothing and the caller stops.
pub fn read_more(reader: &mut Reader, source: &mut dyn Read) -> usize {
    let mut chunk = [0u8; 64];
    match source.read(&mut chunk) {
        Ok(count) => {
            push(reader, &chunk[..count]);
            count
        }
        Err(_) => 0,
    }
}

/// from_hex answers the bytes of a run of hex digits. The wire carries
/// text, so the bytes of a key travel as hex and are read back here.
pub fn from_hex(text: &str) -> Vec<u8> {
    let digits: Vec<char> = text.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    let mut bytes = Vec::new();
    let mut at = 0usize;
    while at + 1 < digits.len() {
        let pair = format!("{}{}", digits[at], digits[at + 1]);
        bytes.push(u8::from_str_radix(&pair, 16).unwrap_or(0));
        at += 2;
    }
    bytes
}

/// to_hex answers a run of bytes as hex: two digits for each byte, so
/// the wire can carry a key that is not a character.
pub fn to_hex(bytes: &[u8]) -> String {
    let mut out = String::new();
    for byte in bytes {
        out.push_str(&format!("{:02x}", byte));
    }
    out
}

/// encode_name answers the bytes of a key name, the way a terminal sends
/// them. It answers nothing when the name is not a key the decoder
/// knows.
pub fn encode_name(name: &str) -> Option<Vec<u8>> {
    keys::encode(name)
}

/// The reader and the decoding, for the hot path above it.
pub use self::keys::Key;
pub use self::keys::decode;
pub use self::Reader as KeyReader;
