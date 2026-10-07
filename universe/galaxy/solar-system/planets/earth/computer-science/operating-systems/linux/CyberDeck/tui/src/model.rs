//! Serde types for the package snapshot JSON.
//!
//! The snapshot is emitted by the package manager (one document listing
//! every known package with its pin and status); the TUI never shells
//! out to gather it. Older documents still parse: unknown fields are
//! ignored and new fields default. See README.md for schema.

use serde::{Deserialize, Serialize};

/// Schema version of the on-disk index format.
pub const SCHEMA_VERSION: u32 = 3;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Header {
    pub schema: u32,
    #[serde(default, alias = "guix_commit")]
    pub state: String,
    #[serde(default)]
    pub generated_ms: String,
    pub package_count: u64,
}

/// One package in the snapshot. The pm writes the plain fields plus
/// source_url/commit/deps/status; legacy fields stay accepted so
/// older documents keep parsing. `index::Index::from_doc` converts
/// these into interned `Arc<str>`s.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PkgJson {
    pub id: u32,
    pub name: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub synopsis: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub homepage: String,
    #[serde(default)]
    pub licenses: Vec<String>,
    /// `[file, line]` as emitted by the script; `["", 0]` when unknown.
    #[serde(default)]
    pub file: (String, u64),
    #[serde(default)]
    pub inputs: Vec<String>,
    #[serde(default)]
    pub propagated_inputs: Vec<String>,
    #[serde(default)]
    pub native_inputs: Vec<String>,
    #[serde(default)]
    pub source_url: String,
    #[serde(default)]
    pub commit: String,
    #[serde(default)]
    pub deps: Vec<String>,
    #[serde(default)]
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexDoc {
    pub header: Header,
    pub packages: Vec<PkgJson>,
}
