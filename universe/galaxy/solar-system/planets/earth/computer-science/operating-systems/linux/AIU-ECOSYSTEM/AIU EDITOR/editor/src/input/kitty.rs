// One job: the kitty keyboard protocol's opt-in flags, adopted not
// invented. The protocol says which flags a terminal may report, and
// the flags are bits: one asks the terminal to report the escape codes
// it would otherwise swallow, and the others ask for more of the event.
//
// The modifiers of a key are the same protocol's: one number, and the
// number is the bits of the modifiers plus one. The names here are the
// ones the keymaps use, and they are the protocol's own.

/// FLAG_DISAMBIGUATE asks the terminal to report the escape codes it
/// would otherwise swallow, so a key is never guessed at.
pub const FLAG_DISAMBIGUATE: u8 = 1;

/// FLAG_EVENT_TYPES asks the terminal to report the kind of event, so
/// a press and a release are told apart.
pub const FLAG_EVENT_TYPES: u8 = 2;

/// FLAG_ALTERNATE_KEYS asks the terminal to report the key that would
/// be typed without the modifier, so the text of a key is known.
pub const FLAG_ALTERNATE_KEYS: u8 = 4;

/// FLAG_ALL_KEYS asks the terminal to report every key as an escape
/// code, so no key is left to the reader's guess.
pub const FLAG_ALL_KEYS: u8 = 8;

/// MOD_SHIFT is the bit of the shift modifier.
pub const MOD_SHIFT: u8 = 1;

/// MOD_ALT is the bit of the alt modifier.
pub const MOD_ALT: u8 = 2;

/// MOD_CTRL is the bit of the control modifier.
pub const MOD_CTRL: u8 = 4;

/// MOD_SUPER is the bit of the super modifier.
pub const MOD_SUPER: u8 = 8;

/// opt_in answers the sequence that asks the terminal for the flags:
/// the protocol's own progressive enhancement, with the mode that sets
/// them. Nothing is written to the terminal here; the sequence is the
/// answer, and the writer is the drawing side.
pub fn opt_in(flags: u8) -> String {
    format!("\x1b[={};1u", flags)
}

/// bits_of answers the modifier bits of a protocol modifier number: the
/// number is the bits plus one, so zero is no modifier at all.
pub fn bits_of(number: u8) -> u8 {
    if number == 0 {
        0
    } else {
        number - 1
    }
}

/// prefix_of answers the prefix a key with these modifier bits carries:
/// C- for control, M- for alt and S- for shift, in that order. A key
/// with no modifier has no prefix, and a key with one is a command and
/// not text.
pub fn prefix_of(bits: u8) -> String {
    let mut prefix = String::new();
    if bits & MOD_CTRL != 0 {
        prefix.push_str("C-");
    }
    if bits & MOD_ALT != 0 {
        prefix.push_str("M-");
    }
    if bits & MOD_SHIFT != 0 {
        prefix.push_str("S-");
    }
    prefix
}
