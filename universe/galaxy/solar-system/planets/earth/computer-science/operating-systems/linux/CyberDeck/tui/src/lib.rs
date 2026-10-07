//! tui — package explorer for the CyberDeck package manager.
//!
//! Reads the CyberDeck package snapshot, caches it as gzipped JSON, and
//! exposes it through a keyboard-first terminal UI: fuzzy search, package
//! details, and dependency / reverse-dependency trees.

pub mod app;
pub mod cache;
pub mod error;
pub mod index;
pub mod indexer;
pub mod model;
pub mod search;
pub mod theme;
pub mod ui;

/// Canonical name and version, used for `--version` output and UI.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
