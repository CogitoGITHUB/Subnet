//! Typed errors for index data, the snapshot loader, and the disk cache.

use thiserror::Error;

/// Validation failures while turning an `IndexDoc` into an in-memory `Index`.
#[derive(Debug, Error)]
pub enum IndexError {
    #[error("snapshot schema {0} unsupported (expected {1})")]
    Schema(u32, u32),
    #[error("package count mismatch: header={0} packages={1}")]
    Count(u64, usize),
    #[error("package id {0} out of range (len {1})")]
    IdOutOfRange(u32, usize),
    #[error("duplicate package id {0}")]
    DuplicateId(u32),
    #[error("package #{0} has an empty name")]
    EmptyName(u32),
    #[error("package `{1}` references unknown dependency `{0}`")]
    UnknownDep(String, String),
}

/// Failures while reading or parsing the package snapshot file.
#[derive(Debug, Error)]
pub enum IndexerError {
    #[error("snapshot file not found; looked at: {0}")]
    NotFound(String),
    #[error("snapshot load failed: {0}")]
    Exited(String),
}

/// Failures while reading, validating, or writing the on-disk cache.
#[derive(Debug, Error)]
pub enum CacheError {
    #[error("cache read failed: {0}")]
    Read(String),
    #[error("cache parse failed: {0}")]
    Parse(String),
    #[error("cache write failed: {0}")]
    Write(String),
    #[error("cache index invalid: {0}")]
    Invalid(#[from] IndexError),
}
