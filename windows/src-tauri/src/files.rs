//! Large / Stale / Duplicate files. The analysis scan (`scan.rs`) collects
//! every file of 1 MB or more; the UI filters that list for Large and Stale,
//! and `find_dupes` narrows it in three passes: same size -> same head+tail ->
//! same SHA-256 of the whole content.

use crate::jobs::{Jobs, Progress};
use crate::scan::Store;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::sync::atomic::Ordering::Relaxed;
use std::sync::Arc;
use std::time::UNIX_EPOCH;

const SAMPLE: u64 = 64 << 10;

#[derive(Serialize, Deserialize, Clone)]
pub struct FileInfo {
    pub(crate) name: String,
    pub(crate) path: String,
    pub(crate) size: u64,
    /// seconds since the Unix epoch
    pub(crate) modified: u64,
}

/// Modification time in seconds since the Unix epoch (0 when unknown).
pub(crate) fn mtime(m: &std::fs::Metadata) -> u64 {
    m.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl FileInfo {
    pub(crate) fn new(e: &std::fs::DirEntry, m: &std::fs::Metadata) -> Self {
        FileInfo {
            name: e.file_name().to_string_lossy().into_owned(),
            path: e.path().to_string_lossy().into_owned(),
            size: m.len(),
            modified: mtime(m),
        }
    }
}

#[derive(Serialize)]
pub struct DupeGroup {
    size: u64,
    /// space freed when every copy but one is removed
    wasted: u64,
    /// sorted oldest first
    items: Vec<FileInfo>,
}

#[derive(Serialize)]
pub struct DupeResult {
    groups: Vec<DupeGroup>,
    /// stopped by the user: only groups that finished matching
    partial: bool,
}

/// Folders whose contents belong to an app or a tool; removing a "duplicate"
/// from inside them breaks the owner.
fn is_protected(path: &str, root: &str) -> bool {
    let p = path.replace('/', "\\").to_lowercase();
    let r = root.replace('/', "\\").to_lowercase();
    for prefix in ["c:\\windows\\", "c:\\program files\\", "c:\\program files (x86)\\", "c:\\programdata\\"] {
        if p.starts_with(prefix) && !r.starts_with(prefix) {
            return true;
        }
    }
    p.split('\\').any(|c| {
        matches!(c, "node_modules" | ".git" | ".svn" | ".hg" | "appdata")
            && !r.split('\\').any(|rc| rc == c)
    })
}

/// SHA-256 of the whole file, or of its first and last SAMPLE bytes.
fn digest(path: &str, size: u64, full: bool, p: &Progress) -> Option<[u8; 32]> {
    if p.cancelled() {
        return None;
    }
    p.set_current(std::path::Path::new(path));
    let mut f = File::open(path).ok()?;
    let mut h = Sha256::new();
    if full {
        let mut buf = vec![0u8; 1 << 20];
        let mut total = 0u64;
        loop {
            if p.cancelled() {
                return None;
            }
            let n = f.read(&mut buf).ok()?;
            if n == 0 {
                break;
            }
            h.update(&buf[..n]);
            total += n as u64;
            p.bytes.fetch_add(n as u64, Relaxed);
        }
        if total != size {
            return None; // file changed while reading
        }
    } else {
        let head = size.min(SAMPLE) as usize;
        let mut buf = vec![0u8; head];
        f.read_exact(&mut buf).ok()?;
        h.update(&buf);
        p.bytes.fetch_add(head as u64, Relaxed);
        if size > SAMPLE {
            let tail = SAMPLE.min(size - SAMPLE) as usize;
            let mut buf = vec![0u8; tail];
            f.seek(SeekFrom::Start(size - tail as u64)).ok()?;
            f.read_exact(&mut buf).ok()?;
            h.update(&buf);
            p.bytes.fetch_add(tail as u64, Relaxed);
        }
    }
    Some(h.finalize().into())
}

fn hash_all(files: &[FileInfo], full: bool, p: &Progress) -> Vec<Option<[u8; 32]>> {
    files
        .par_iter()
        .map(|f| {
            let k = digest(&f.path, f.size, full, p);
            p.done.fetch_add(1, Relaxed);
            k
        })
        .collect()
}

fn dupe_groups(files: Vec<FileInfo>, root: &str, skip_protected: bool, p: &Progress) -> Vec<DupeGroup> {
    // 1. same size
    let mut by_size: HashMap<u64, Vec<FileInfo>> = HashMap::new();
    for f in files {
        if f.size == 0 || (skip_protected && is_protected(&f.path, root)) {
            continue;
        }
        by_size.entry(f.size).or_default().push(f);
    }
    let quick: Vec<FileInfo> = by_size.into_values().filter(|g| g.len() > 1).flatten().collect();
    // progress counts each file once per pass it takes part in
    p.total.store(quick.len() as u64, Relaxed);

    // 2. head + tail
    let keys = hash_all(&quick, false, p);
    let mut by_quick: HashMap<(u64, [u8; 32]), Vec<FileInfo>> = HashMap::new();
    for (f, k) in quick.into_iter().zip(keys) {
        if let Some(k) = k {
            by_quick.entry((f.size, k)).or_default().push(f);
        }
    }

    // 3. whole content (files no bigger than head + tail were read already)
    let mut groups: Vec<Vec<FileInfo>> = Vec::new();
    let mut full: Vec<FileInfo> = Vec::new();
    for ((size, _), g) in by_quick {
        if g.len() < 2 {
            continue;
        }
        if size <= 2 * SAMPLE {
            groups.push(g);
        } else {
            full.extend(g);
        }
    }
    p.total.fetch_add(full.len() as u64, Relaxed);
    let keys = hash_all(&full, true, p);
    let mut by_full: HashMap<(u64, [u8; 32]), Vec<FileInfo>> = HashMap::new();
    for (f, k) in full.into_iter().zip(keys) {
        if let Some(k) = k {
            by_full.entry((f.size, k)).or_default().push(f);
        }
    }
    groups.extend(by_full.into_values().filter(|g| g.len() > 1));

    let mut out: Vec<DupeGroup> = groups
        .into_iter()
        .map(|mut items| {
            items.sort_by_key(|f| f.modified);
            let size = items[0].size;
            DupeGroup { size, wasted: size * (items.len() as u64 - 1), items }
        })
        .collect();
    out.sort_by(|a, b| b.wasted.cmp(&a.wasted));
    out
}

/// Duplicates among the files of the last analysis.
#[tauri::command]
pub async fn find_dupes(
    root: String,
    skip_protected: bool,
    jobs: tauri::State<'_, Arc<Jobs>>,
    store: tauri::State<'_, Arc<Store>>,
) -> Result<DupeResult, String> {
    let (jobs, store) = (jobs.inner().clone(), store.inner().clone());
    tauri::async_runtime::spawn_blocking(move || {
        let files = match store.0.lock().unwrap().as_ref() {
            Some(a) => a.files.clone(),
            None => return Err("Nothing scanned yet".to_string()),
        };
        let p = &jobs.dupes;
        let Some(_running) = p.start() else { return Err("A search is already running".into()) };
        let groups = dupe_groups(files, &root, skip_protected, p);
        Ok(DupeResult { groups, partial: p.cancelled() })
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Moves files or folders to the Recycle Bin and drops them from the last
/// analysis. Returns the paths that failed.
#[tauri::command]
pub async fn trash_paths(paths: Vec<String>, store: tauri::State<'_, Arc<Store>>) -> Result<Vec<String>, String> {
    let store = store.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut failed = Vec::new();
        let mut done = Vec::new();
        for p in paths {
            // measure first: afterwards the file is gone
            let (size, is_dir) = match store.0.lock().unwrap().as_ref() {
                Some(a) => a.size_of(std::path::Path::new(&p)),
                None => (0, false),
            };
            match trash::delete(&p) {
                Ok(()) => done.push((p, size, is_dir)),
                Err(_) => failed.push(p),
            }
        }
        if let Some(a) = store.0.lock().unwrap().as_mut() {
            a.forget(&done);
        }
        failed
    })
    .await
    .map_err(|e| e.to_string())
}

/// Opens Explorer with the items selected (one window per folder).
#[tauri::command]
pub fn reveal(paths: Vec<String>) {
    let mut seen = std::collections::HashSet::new();
    for p in paths.into_iter().take(10) {
        let parent = std::path::Path::new(&p).parent().map(|d| d.to_path_buf());
        if seen.insert(parent) {
            let _ = std::process::Command::new("explorer").arg(format!("/select,{p}")).spawn();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::path::Path;

    fn mk(dir: &Path, name: &str, data: &[u8]) -> FileInfo {
        let p = dir.join(name);
        File::create(&p).unwrap().write_all(data).unwrap();
        FileInfo {
            name: name.into(),
            path: p.to_string_lossy().into_owned(),
            size: data.len() as u64,
            modified: 0,
        }
    }

    #[test]
    fn finds_only_true_duplicates() {
        let dir = std::env::temp_dir().join(format!("cleanbro-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let big = vec![7u8; 300_000]; // larger than head+tail, so the full pass runs
        let mut almost = big.clone();
        almost[150_000] = 8; // same size/head/tail, different middle
        let files = vec![
            mk(&dir, "a.bin", &big),
            mk(&dir, "b.bin", &big),
            mk(&dir, "c.bin", &almost),
            mk(&dir, "s1.txt", b"hello"),
            mk(&dir, "s2.txt", b"hello"),
            mk(&dir, "other.txt", b"world"),
        ];
        let p = Progress::default();
        let _r = p.start().unwrap();
        let groups = dupe_groups(files, &dir.to_string_lossy(), false, &p);
        std::fs::remove_dir_all(&dir).ok();
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].size, 300_000);
        assert_eq!(groups[0].items.len(), 2);
        assert_eq!(groups[1].items.len(), 2);
        // all 6 share a size with another file; a, b and c also match on
        // head + tail and get the full pass
        assert_eq!(p.total.load(Relaxed), 9);
        assert_eq!(p.done.load(Relaxed), 9);
    }
}
