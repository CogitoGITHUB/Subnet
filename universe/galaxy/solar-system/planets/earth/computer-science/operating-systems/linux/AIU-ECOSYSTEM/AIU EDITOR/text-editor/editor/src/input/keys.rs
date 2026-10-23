// One job: the key decoding — the raw bytes of a terminal become the
// name of a key, the way the keymaps name it. The names are the ones the
// meaning side uses: a plain key is its character, a key with a modifier
// is prefixed with C-, M- or S-, and a named key is a word.
//
// The decoding is the hot path's job (rule 09): it is the side that sees
// the bytes. The keymaps stay in Racket, and this file never holds a
// key of its own.
//
// The kitty keyboard protocol is adopted, not invented: a key that
// carries modifiers comes as one number, and the flags the terminal is
// asked for are in kitty.rs.

#[path = "kitty.rs"]
mod kitty;

/// Key is one key: the name the keymaps use, and the number of bytes it
/// took from the stream. The bytes matter because a terminal sends more
/// than one key at a time, and the reader must know where the next one
/// starts.
pub struct Key {
    pub name: String,
    pub length: usize,
}

/// named-keys are the keys that have a word of their own. The word is
/// the name of the key, and the name is what the keymaps use.
const NAMED_KEYS: [(&str, &str); 20] = [
    ("\x1b[A", "up"),
    ("\x1b[B", "down"),
    ("\x1b[C", "right"),
    ("\x1b[D", "left"),
    ("\x1b[H", "home"),
    ("\x1b[F", "end"),
    ("\x1b[1~", "home"),
    ("\x1b[2~", "insert"),
    ("\x1b[3~", "delete"),
    ("\x1b[4~", "end"),
    ("\x1b[5~", "pageup"),
    ("\x1b[6~", "pagedown"),
    ("\x1b[11~", "f1"),
    ("\x1b[12~", "f2"),
    ("\x1b[13~", "f3"),
    ("\x1b[14~", "f4"),
    ("\x1b[15~", "f5"),
    ("\x1b[17~", "f6"),
    ("\x1b[18~", "f7"),
    ("\x1b[19~", "f8"),
];

/// decode answers the first key in the bytes, or nothing when the bytes
/// hold no whole key yet. A lone escape is the escape key, and the
/// reader asks again when the next byte decides it.
pub fn decode(bytes: &[u8]) -> Option<Key> {
    if bytes.is_empty() {
        return None;
    }
    for (sequence, name) in NAMED_KEYS.iter() {
        if bytes.starts_with(sequence.as_bytes()) {
            return Some(Key {
                name: name.to_string(),
                length: sequence.len(),
            });
        }
    }
    let first = bytes[0];
    if first == 0x1b {
        // An escape on its own is the escape key; a second byte makes it
        // the alt modifier, which the kitty flags report on their own.
        if bytes.len() == 1 {
            return Some(Key {
                name: "escape".to_string(),
                length: 1,
            });
        }
        return Some(Key {
            name: format!("M-{}", plain_name(bytes[1])),
            length: 2,
        });
    }
    if first == 0x09 {
        return Some(Key {
            name: "tab".to_string(),
            length: 1,
        });
    }
    if first == 0x0d || first == 0x0a {
        return Some(Key {
            name: "return".to_string(),
            length: 1,
        });
    }
    if first == 0x7f {
        return Some(Key {
            name: "backspace".to_string(),
            length: 1,
        });
    }
    if first == 0x20 {
        return Some(Key {
            name: "space".to_string(),
            length: 1,
        });
    }
    if first < 0x20 {
        return Some(Key {
            name: format!("C-{}", plain_name(first + 0x60)),
            length: 1,
        });
    }
    Some(Key {
        name: plain_name(first),
        length: 1,
    })
}

/// plain_name answers the name of one plain byte: the character itself,
/// or a word for the few bytes that have one.
fn plain_name(byte: u8) -> String {
    match byte {
        b' ' => "space".to_string(),
        _ => (byte as char).to_string(),
    }
}

/// decode_csi answers the key of a kitty control sequence: the sequence
/// carries the key's code and its modifiers as two numbers, and the
/// name is the character with the modifiers' prefix. The sequence is
/// the protocol's own: ESC [ code ; modifiers u.
pub fn decode_csi(body: &str) -> Option<Key> {
    let mut parts = body.split(';');
    let code: u32 = parts.next()?.parse().ok()?;
    let modifiers: u8 = match parts.next() {
        Some(value) => value.parse().ok()?,
        None => 0,
    };
    let bits = kitty::bits_of(modifiers);
    let character = char::from_u32(code)?;
    Some(Key {
        name: format!("{}{}", kitty::prefix_of(bits), character),
        length: body.len() + 3,
    })
}

/// encode answers the bytes of a key name: the bytes a terminal sends
/// for that key. The answer is the way round of the decoding, and it
/// lives here with it, so the two can never drift apart: the check asks
/// the hot path to name a key and then to spell it, and the names must
/// come back the same.
pub fn encode(name: &str) -> Option<Vec<u8>> {
    for (sequence, key) in NAMED_KEYS.iter() {
        if *key == name {
            return Some(sequence.as_bytes().to_vec());
        }
    }
    if name == "escape" {
        return Some(vec![0x1b]);
    }
    if name == "tab" {
        return Some(vec![0x09]);
    }
    if name == "return" {
        return Some(vec![0x0d]);
    }
    if name == "backspace" {
        return Some(vec![0x7f]);
    }
    if name == "space" {
        return Some(vec![0x20]);
    }
    if let Some(rest) = name.strip_prefix("C-") {
        let mut chars = rest.chars();
        if let (Some(letter), None) = (chars.next(), chars.next()) {
            if letter.is_ascii_lowercase() {
                return Some(vec![(letter as u8) - 0x60]);
            }
        }
    }
    if let Some(rest) = name.strip_prefix("M-") {
        let mut chars = rest.chars();
        if let (Some(letter), None) = (chars.next(), chars.next()) {
            if letter.is_ascii_lowercase() {
                return Some(vec![0x1b, letter as u8]);
            }
        }
    }
    let mut chars = name.chars();
    if let (Some(letter), None) = (chars.next(), chars.next()) {
        return Some(vec![letter as u8]);
    }
    None
}

/// The decoding, for the hot path above it.
pub use self::Key as DecodedKey;
