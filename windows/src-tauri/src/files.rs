//! Large / Stale / Duplicate files. One scan collects every file above a
//! minimum size; the UI filters it for Large and Stale, and `find_dupes`
//! narrows candidates in three passes: same size -> same head+tail -> same
//! SHA-256 of the whole content.

use jwalk::WalkDir;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::time::UNIX_EPOCH;

const SAMPLE: u64 = 64 << 10;

#[derive(Serialize, Deserialize, Clone)]
pub struct FileInfo {
    name: String,
    path: String,
    size: u64,
    /// seconds since the Unix epoch
    modified: u64,
}

#[derive(Serialize)]
pub struct DupeGroup {
    size: u64,
    /// space freed when every copy but one is removed
    wasted: u64,
    /// sorted oldest first
    items: Vec<FileInfo>,
}

fn secs(t: std::io::Result<std::time::SystemTime>) -> u64 {
    t.ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[tauri::command]
pub async fn scan_files(root: String, min_bytes: u64) -> Result<Vec<FileInfo>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        if !Path::new(&root).is_dir() {
            return Err(format!("Not a folder: {root}"));
        }
        let mut out: Vec<FileInfo> = WalkDir::new(&root)
            .skip_hidden(false)
            .follow_links(false)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_file())
            .filter_map(|e| {
                let m = e.metadata().ok()?;
                if m.len() < min_bytes {
                    return None;
                }
                Some(FileInfo {
                    name: e.file_name().to_string_lossy().into_owned(),
                    path: e.path().to_string_lossy().into_owned(),
                    size: m.len(),
                    modified: secs(m.modified()),
                })
            })
            .collect();
        out.sort_by(|a, b| b.size.cmp(&a.size));
        Ok(out)
    })
    .await
    .map_err(|e| e.to_string())?
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
fn digest(path: &str, size: u64, full: bool) -> Option<[u8; 32]> {
    let mut f = File::open(path).ok()?;
    let mut h = Sha256::new();
    if full {
        let mut buf = vec![0u8; 1 << 20];
        let mut total = 0u64;
        loop {
            let n = f.read(&mut buf).ok()?;
            if n == 0 {
                break;
            }
            h.update(&buf[..n]);
            total += n as u64;
        }
        if total != size {
            return None; // file changed while reading
        }
    } else {
        let head = size.min(SAMPLE) as usize;
        let mut buf = vec![0u8; head];
        f.read_exact(&mut buf).ok()?;
        h.update(&buf);
        if size > SAMPLE {
            let tail = SAMPLE.min(size - SAMPLE) as usize;
            let mut buf = vec![0u8; tail];
            f.seek(SeekFrom::Start(size - tail as u64)).ok()?;
            f.read_exact(&mut buf).ok()?;
            h.update(&buf);
        }
    }
    Some(h.finalize().into())
}

#[tauri::command]
pub async fn find_dupes(
    files: Vec<FileInfo>,
    root: String,
    skip_protected: bool,
) -> Result<Vec<DupeGroup>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        // 1. same size
        let mut by_size: HashMap<u64, Vec<FileInfo>> = HashMap::new();
        for f in files {
            if f.size == 0 || (skip_protected && is_protected(&f.path, &root)) {
                continue;
            }
            by_size.entry(f.size).or_default().push(f);
        }
        let quick: Vec<FileInfo> = by_size
            .into_values()
            .filter(|g| g.len() > 1)
            .flatten()
            .collect();

        // 2. head + tail
        let keys: Vec<Option<[u8; 32]>> = quick
            .par_iter()
            .map(|f| digest(&f.path, f.size, false))
            .collect();
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
        let keys: Vec<Option<[u8; 32]>> = full
            .par_iter()
            .map(|f| digest(&f.path, f.size, true))
            .collect();
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
        Ok(out)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Moves files to the Recycle Bin. Returns the paths that failed.
#[tauri::command]
pub async fn trash_paths(paths: Vec<String>) -> Result<Vec<String>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        paths
            .into_iter()
            .filter(|p| trash::delete(p).is_err())
            .collect()
    })
    .await
    .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

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
        let groups = tauri::async_runtime::block_on(find_dupes(
            files,
            dir.to_string_lossy().into_owned(),
            false,
        ))
        .unwrap();
        std::fs::remove_dir_all(&dir).ok();
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].size, 300_000);
        assert_eq!(groups[0].items.len(), 2);
        assert_eq!(groups[1].items.len(), 2);
    }
}
