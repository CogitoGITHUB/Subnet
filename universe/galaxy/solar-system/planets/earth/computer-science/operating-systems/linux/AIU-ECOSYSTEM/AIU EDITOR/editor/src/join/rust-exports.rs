// One job: the functions the meaning side may call, one per crossing. The
// meaning side is Racket and the hot path is Rust; this file names every
// crossing between them, so the seam is written down in one place.
//
// A crossing is an operation on the wire: the name the meaning side sends,
// and what the hot path does when it arrives. The names are constants, so
// the two sides of a crossing speak the same word by construction.

/// OP_OPEN reads the file and the journal, and answers what the text is.
pub const OP_OPEN: &str = "open";

/// OP_INSERT appends text to the buffer and journals the edit.
pub const OP_INSERT: &str = "insert";

/// OP_SAVE writes the buffer to the file and clears the journal.
pub const OP_SAVE: &str = "save";

/// OP_SHOW answers the text of the buffer.
pub const OP_SHOW: &str = "show";

/// OP_JOURNAL answers the records of the journal.
pub const OP_JOURNAL: &str = "journal";

/// OP_REPLAY rebuilds the state after a crash: the file with the journal's
/// unsaved edits put back on top, the pending count and the records.
pub const OP_REPLAY: &str = "replay";
