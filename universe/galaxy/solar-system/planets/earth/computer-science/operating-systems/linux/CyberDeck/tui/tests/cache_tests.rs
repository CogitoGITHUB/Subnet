//! Cache round-trip, validation, and quarantine behavior.

mod common;

use std::fs;
use std::path::PathBuf;

use tui::cache::{Cache, CacheStatus};
use tui::model::IndexDoc;

use common::load_fixture;

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("tui-test-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

#[test]
fn round_trip_save_and_load() {
    let dir = temp_dir("roundtrip");
    let cache = Cache::at(dir.clone());
    let doc: IndexDoc = serde_json::from_str(include_str!("fixtures/small.json")).unwrap();
    let raw = serde_json::to_vec(&doc).unwrap();
    cache.save(&raw).expect("save");

    let status = cache.load().expect("load");
    let CacheStatus::Fresh(loaded) = status else {
        panic!("expected Fresh, got {status:?}");
    };
    assert_eq!(loaded.header.state, "testcommit");
    assert_eq!(loaded.packages.len(), 10);
    assert_eq!(loaded.packages[0].status, "installed");
    fs::remove_dir_all(dir).ok();
}

#[test]
fn absent_cache_reports_absent() {
    let dir = temp_dir("absent");
    let cache = Cache::at(dir.clone());
    let status = cache.load().expect("load");
    assert!(matches!(status, CacheStatus::Absent));
    fs::remove_dir_all(dir).ok();
}

#[test]
fn corrupt_cache_is_quarantined_not_deleted() {
    let dir = temp_dir("corrupt");
    let cache = Cache::at(dir.clone());
    fs::write(cache.path(), b"this is not gzip data").expect("write garbage");

    let result = cache.load();
    assert!(result.is_err());
    cache.quarantine();
    assert!(!cache.path().exists(), "corrupt cache moved away");
    let leftovers: Vec<_> = fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().contains("corrupt"))
        .collect();
    assert_eq!(leftovers.len(), 1, "quarantined file kept for evidence");
    fs::remove_dir_all(dir).ok();
}

#[test]
fn fixture_index_builds_from_cache_doc() {
    let doc: IndexDoc = serde_json::from_str(include_str!("fixtures/small.json")).unwrap();
    let index = tui::index::Index::from_doc(doc, 42).expect("build");
    let _ = load_fixture();
    assert_eq!(index.built_ms, 42);
    assert_eq!(index.len(), 10);
}
