//! The loader: reads the package snapshot JSON file, validates it into
//! an [`Index`], and emits typed events to the UI thread. A gzipped copy
//! of the last good snapshot lives in the disk cache for instant startup;
//! `--rebuild` (or a missing cache) re-reads the snapshot file. The loader
//! never shells out: gathering data is the package manager's job.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::thread::JoinHandle;

use crate::cache::{Cache, CacheStatus};
use crate::error::IndexerError;
use crate::index::Index;

pub enum IndexEvent {
    /// Snapshot read started (`done`/`total` stay 0; kept for UI compat).
    Progress { done: u64, total: u64 },
    /// A valid index is available (from cache or a fresh snapshot read).
    Ready {
        index: std::sync::Arc<crate::index::Index>,
        fresh: bool,
    },
    /// The load failed; `msg` is safe to show in the status bar.
    Failed { msg: String },
}

/// Cancellation token shared with the loader thread.
pub type Cancel = Arc<AtomicBool>;

/// Resolve which snapshot file to read: explicit CLI path first, then
/// `$CYBERDECK_SNAPSHOT`, else `./snapshot.json`.
pub fn resolve_snapshot(explicit: Option<PathBuf>) -> PathBuf {
    if let Some(p) = explicit {
        return p;
    }
    if let Some(env) = std::env::var_os("CYBERDECK_SNAPSHOT") {
        if !env.is_empty() {
            return PathBuf::from(env);
        }
    }
    PathBuf::from("snapshot.json")
}

/// Load the index from cache or the snapshot file; runs on its own
/// thread and reports through `tx`.
pub fn start_loader(
    tx: Sender<IndexEvent>,
    cancel: Cancel,
    force: bool,
    snapshot: PathBuf,
) -> JoinHandle<()> {
    std::thread::Builder::new()
        .name("tui-loader".into())
        .spawn(move || {
            let now_ms = || -> u64 {
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_millis() as u64)
                    .unwrap_or(0)
            };
            if cancel.load(Ordering::Relaxed) {
                return;
            }

            if !force {
                if let Ok(cache) = Cache::new() {
                    match cache.load() {
                        Ok(CacheStatus::Fresh(doc)) => match Index::from_doc(doc, now_ms()) {
                            Ok(index) => {
                                let _ = tx.send(IndexEvent::Ready {
                                    index: Arc::new(index),
                                    fresh: true,
                                });
                                return;
                            }
                            Err(e) => {
                                let _ = tx.send(IndexEvent::Failed {
                                    msg: format!("cached index rejected ({e}); re-reading snapshot"),
                                });
                                cache.quarantine();
                            }
                        },
                        Ok(CacheStatus::Absent) => {
                            let _ = tx.send(IndexEvent::Progress { done: 0, total: 0 });
                        }
                        Err(e) => {
                            let _ = tx.send(IndexEvent::Failed {
                                msg: format!("cache unreadable ({e}); re-reading snapshot"),
                            });
                            cache.quarantine();
                        }
                    }
                }
            }

            if cancel.load(Ordering::Relaxed) {
                return;
            }
            // Snapshot path: read the file, then refresh the cache.
            match read_snapshot(&snapshot) {
                Ok((doc, raw)) => {
                    if let Ok(cache) = Cache::new() {
                        if let Err(e) = cache.save(&raw) {
                            let _ = tx.send(IndexEvent::Failed {
                                msg: format!("cache save failed: {e}"),
                            });
                        }
                    }
                    match Index::from_doc(doc, now_ms()) {
                        Ok(index) => {
                            let _ = tx.send(IndexEvent::Ready {
                                index: Arc::new(index),
                                fresh: false,
                            });
                        }
                        Err(e) => {
                            let _ = tx.send(IndexEvent::Failed {
                                msg: format!("snapshot invalid: {e}"),
                            });
                        }
                    }
                }
                Err(e) => {
                    let _ = tx.send(IndexEvent::Failed {
                        msg: format!("snapshot load failed: {e}"),
                    });
                }
            }
        })
        .expect("failed to spawn loader thread")
}

/// Read and parse the snapshot file; returns the document plus its raw
/// bytes (for the cache). Blocking; call from a worker thread.
pub fn read_snapshot(
    path: &PathBuf,
) -> Result<(crate::model::IndexDoc, Vec<u8>), IndexerError> {
    let raw = std::fs::read(path).map_err(|e| {
        IndexerError::NotFound(format!("{} ({e})", path.to_string_lossy()))
    })?;
    if raw.is_empty() {
        return Err(IndexerError::Exited("snapshot file is empty".into()));
    }
    if raw.len() > 256 * 1024 * 1024 {
        return Err(IndexerError::Exited(
            "snapshot exceeds 256 MiB; refusing".into(),
        ));
    }
    let doc: crate::model::IndexDoc = serde_json::from_slice(&raw)
        .map_err(|e| IndexerError::Exited(format!("cannot parse snapshot JSON: {e}")))?;
    Ok((doc, raw))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_fixture_snapshot() {
        let path = PathBuf::from("tests/fixtures/small.json");
        let (doc, raw) = read_snapshot(&path).expect("fixture reads");
        assert_eq!(doc.packages.len(), 10);
        assert!(!raw.is_empty());
        let index = Index::from_doc(doc, 0).expect("fixture validates");
        assert_eq!(index.len(), 10);
    }

    #[test]
    fn missing_snapshot_is_not_found() {
        let path = PathBuf::from("tests/fixtures/does-not-exist.json");
        let err = read_snapshot(&path).expect_err("missing file fails");
        assert!(matches!(err, IndexerError::NotFound(_)));
    }

    #[test]
    fn explicit_path_wins_resolution() {
        let explicit = PathBuf::from("/tmp/custom-snapshot.json");
        assert_eq!(resolve_snapshot(Some(explicit.clone())), explicit);
        // Without env or flag, the local default applies.
        assert_eq!(resolve_snapshot(None), PathBuf::from("snapshot.json"));
    }
}
