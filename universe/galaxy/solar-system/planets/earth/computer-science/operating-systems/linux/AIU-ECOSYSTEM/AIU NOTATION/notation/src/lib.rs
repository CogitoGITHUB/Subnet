//! One job: the module list — which area files belong to the crate.
//! Registered in plan/package-tree.org.
//!
//! `#[path]` is used on purpose: every area file lives exactly where the tree
//! in plan/package-tree.org lists it, so no per-area module file is invented
//! just to make the compiler happy. The reader must be able to find each file
//! by name in the register, and the register stays the source for it.
//!
//! Areas, lowest first. A module may use the ones below it and never the ones
//! above; gate/one-way-dependency-lint.nu enforces the same table for Racket.

#[path = "text/buffer.rs"]
pub mod buffer;

#[path = "text/positions.rs"]
pub mod positions;

#[path = "parser/parser.rs"]
pub mod parser;

#[path = "join/rust-exports.rs"]
pub mod rust_exports;

#[path = "rendering/strip.rs"]
pub mod strip;

#[path = "rendering/plain.rs"]
pub mod plain;