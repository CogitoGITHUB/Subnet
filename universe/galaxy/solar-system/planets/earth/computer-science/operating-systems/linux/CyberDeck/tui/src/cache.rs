//! Gzipped JSON index cache under `$XDG_CACHE_HOME/tui/`.
//!
//! Writes are transactional (temp file + atomic rename); corrupt files are
//! quarantined instead of silently deleted.

use std::fs::{self, File};
use std::io::{BufReader, Write};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;

use crate::error::CacheError;
use crate::model::IndexDoc;

/// Whether a cached document is usable.
#[derive(Debug)]
pub enum CacheStatus {
    /// Cache parsed successfully.
    Fresh(IndexDoc),
    /// No cache file present.
    Absent,
}

pub struct Cache {
    dir: PathBuf,
}

impl Cache {
    pub fn new() -> Result<Self, CacheError> {
        let base = dirs::cache_dir().ok_or_else(|| {
            CacheError::Read("no cache directory available (XDG_CACHE_HOME unset?)".into())
        })?;
        let dir = base.join("tui");
        fs::create_dir_all(&dir).map_err(|e| CacheError::Read(e.to_string()))?;
        Ok(Cache { dir })
    }

    /// Build a cache rooted at an explicit directory (used by tests).
    pub fn at(dir: PathBuf) -> Self {
        let _ = fs::create_dir_all(&dir);
        Cache { dir }
    }

    pub fn path(&self) -> PathBuf {
        self.dir.join("index-v3.json.gz")
    }

    /// Load and deserialize the cache. The snapshot file is the source of
    /// truth; the cache is only a fast path (pass `--rebuild` or delete
    /// the cache dir to re-read the snapshot).
    pub fn load(&self) -> Result<CacheStatus, CacheError> {
        let path = self.path();
        if !path.exists() {
            return Ok(CacheStatus::Absent);
        }
        let file = File::open(&path).map_err(|e| CacheError::Read(e.to_string()))?;
        let decoder = GzDecoder::new(BufReader::new(file));
        let doc: IndexDoc =
            serde_json::from_reader(decoder).map_err(|e| CacheError::Parse(e.to_string()))?;
        Ok(CacheStatus::Fresh(doc))
    }

    /// Atomically persist raw index JSON bytes (gzip-compressed).
    pub fn save(&self, json_bytes: &[u8]) -> Result<(), CacheError> {
        let tmp = self
            .dir
            .join(format!("index-v3.json.gz.tmp-{}", std::process::id()));
        let result = (|| -> Result<(), CacheError> {
            let file = File::create(&tmp).map_err(|e| CacheError::Write(e.to_string()))?;
            let mut enc = GzEncoder::new(file, Compression::new(6));
            enc.write_all(json_bytes)
                .map_err(|e| CacheError::Write(e.to_string()))?;
            let file = enc.finish().map_err(|e| CacheError::Write(e.to_string()))?;
            file.sync_all()
                .map_err(|e| CacheError::Write(e.to_string()))?;
            fs::rename(&tmp, self.path()).map_err(|e| CacheError::Write(e.to_string()))
        })();
        if result.is_err() {
            let _ = fs::remove_file(&tmp);
        }
        result
    }

    /// Move a broken cache file out of the way instead of deleting evidence.
    pub fn quarantine(&self) {
        let path = self.path();
        if !path.exists() {
            return;
        }
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let dest = self.dir.join(format!("index-v3.json.gz.corrupt-{ts}"));
        let _ = fs::rename(&path, &dest);
    }
}
