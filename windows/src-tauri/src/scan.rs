//! Analysis scan, like the macOS app: one pass over the chosen folder builds a
//! tree of folder sizes (Disk Usage) and the list of files of 1 MB or more
//! (Large, Stale and Duplicates). The tree stays here; the UI asks for one
//! folder's children at a time, so browsing never rescans.

use crate::files::FileInfo;
use crate::jobs::{Jobs, Progress};
use rayon::prelude::*;
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

/// Files at least this big are kept for Large, Stale and Duplicates.
pub const BIG: u64 = 1 << 20;

#[tauri::command]
pub fn home_dir() -> String {
    std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_default()
}

/// Walks `dir` in parallel, calling `on_file` for every regular file, and
/// returns the total size of those files. Symlinks and junctions are not
/// followed.
///
/// Uses `std::fs::DirEntry::metadata`, which on Windows comes for free from
/// `FindNextFileW`. `jwalk::DirEntry::metadata` calls `symlink_metadata` on the
/// path instead, which opens every file (and wakes up the antivirus): ~10x
/// slower on a home folder with ~1.8M files (351s vs 24-35s).
///
/// Built on plain rayon, so it is safe to call from inside another rayon job.
pub(crate) fn walk<F>(dir: &Path, on_file: &F) -> u64
where
    F: Fn(&fs::DirEntry, &fs::Metadata) + Sync,
{
    let Ok(rd) = fs::read_dir(dir) else { return 0 };
    let mut subdirs = Vec::new();
    let mut total = 0;
    for e in rd.flatten() {
        let Ok(m) = e.metadata() else { continue };
        let ft = m.file_type();
        if ft.is_symlink() {
            continue;
        }
        if ft.is_dir() {
            subdirs.push(e.path());
        } else if ft.is_file() {
            total += m.len();
            on_file(&e, &m);
        }
    }
    total + subdirs.par_iter().map(|d| walk(d, on_file)).sum::<u64>()
}

pub(crate) fn dir_size(p: &Path) -> u64 {
    walk(p, &|_, _| {})
}

// ---------- analysis tree ----------

pub struct Node {
    name: Box<str>,
    size: u64,
    /// newest modification time of any file inside (seconds, 0 = none)
    modified: u64,
    children: Vec<Node>,
}

struct Ctx<'a> {
    progress: &'a Progress,
    big: Mutex<Vec<FileInfo>>,
    unreadable: AtomicU64,
}

/// Progress of a folder scan, whose total size is unknown until it ends: the
/// whole scan is worth `PROGRESS_TOTAL`, each folder splits its share evenly
/// among its subfolders, down to `PROGRESS_DEPTH` levels, and a share counts
/// as done when that subtree finishes. It only ever goes up.
pub const PROGRESS_TOTAL: u64 = 1_000_000_000;
const PROGRESS_DEPTH: usize = 4;

fn build(dir: &Path, name: Box<str>, ctx: &Ctx, depth: usize, share: u64) -> Node {
    let p = ctx.progress;
    if p.cancelled() {
        p.done.fetch_add(share, Relaxed);
        return Node { name, size: 0, modified: 0, children: Vec::new() };
    }
    p.dirs.fetch_add(1, Relaxed);
    p.set_current(dir);
    let mut subdirs = Vec::new();
    let (mut size, mut files, mut newest) = (0u64, 0u64, 0u64);
    let mut big = Vec::new();
    match fs::read_dir(dir) {
        Err(_) => {
            ctx.unreadable.fetch_add(1, Relaxed);
        }
        Ok(rd) => {
            for e in rd.flatten() {
                let Ok(m) = e.metadata() else { continue };
                let ft = m.file_type();
                if ft.is_symlink() {
                    continue;
                }
                if ft.is_dir() {
                    subdirs.push((e.path(), e.file_name().to_string_lossy().into()));
                } else if ft.is_file() {
                    size += m.len();
                    files += 1;
                    newest = newest.max(crate::files::mtime(&m));
                    if m.len() >= BIG {
                        big.push(FileInfo::new(&e, &m));
                    }
                }
            }
        }
    }
    p.files.fetch_add(files, Relaxed);
    p.bytes.fetch_add(size, Relaxed);
    if !big.is_empty() {
        ctx.big.lock().unwrap().extend(big);
    }
    // hand the share down, or keep it and count it when this subtree is done
    let split = depth < PROGRESS_DEPTH && !subdirs.is_empty();
    let (each, kept) = if split {
        let n = subdirs.len() as u64;
        (share / n, share - share / n * n)
    } else {
        (0, share)
    };
    if split {
        p.done.fetch_add(kept, Relaxed); // rounding leftover
    }
    let mut children: Vec<Node> = subdirs
        .into_par_iter()
        .map(|(path, name)| build(&path, name, ctx, depth + 1, each))
        .collect();
    if !split {
        p.done.fetch_add(kept, Relaxed);
    }
    size += children.iter().map(|c| c.size).sum::<u64>();
    let modified = children.iter().map(|c| c.modified).fold(newest, u64::max);
    children.sort_by(|a, b| b.size.cmp(&a.size));
    Node { name, size, modified, children }
}

pub struct Analysis {
    root: PathBuf,
    tree: Node,
    pub(crate) files: Vec<FileInfo>,
}

impl Analysis {
    fn find(&self, p: &Path) -> Option<&Node> {
        let rel = p.strip_prefix(&self.root).ok()?;
        let mut n = &self.tree;
        for c in rel.components() {
            let name = c.as_os_str().to_string_lossy();
            n = n.children.iter().find(|x| *x.name == *name)?;
        }
        Some(n)
    }

    /// Size of `path` as the last scan saw it: a folder from the tree, a file
    /// from its own metadata. Call before removing it.
    pub(crate) fn size_of(&self, path: &Path) -> (u64, bool) {
        if let Some(n) = self.find(path) {
            if path != self.root {
                return (n.size, true);
            }
        }
        (fs::symlink_metadata(path).map(|m| m.len()).unwrap_or(0), false)
    }

    /// Drops removed files and folders (with their sizes from `size_of`) from
    /// the file list and the tree.
    pub(crate) fn forget(&mut self, removed: &[(String, u64, bool)]) {
        for (path, size, is_dir) in removed {
            let p = Path::new(path);
            if *is_dir {
                let inside = |f: &FileInfo| Path::new(&f.path).starts_with(p);
                self.files.retain(|f| !inside(f));
            } else {
                self.files.retain(|f| f.path != *path);
            }
            let Some(rel) = p.parent().and_then(|d| d.strip_prefix(&self.root).ok()) else { continue };
            let mut n = &mut self.tree;
            n.size = n.size.saturating_sub(*size);
            for c in rel.components() {
                let name = c.as_os_str().to_string_lossy();
                let Some(i) = n.children.iter().position(|x| *x.name == *name) else { break };
                n = &mut n.children[i];
                n.size = n.size.saturating_sub(*size);
            }
            if *is_dir {
                let name = p.file_name().map(|s| s.to_string_lossy()).unwrap_or_default();
                n.children.retain(|x| *x.name != *name);
            }
        }
    }
}

/// The last finished analysis, shared by Disk Usage, Large, Stale and Duplicates.
#[derive(Default)]
pub struct Store(pub Mutex<Option<Analysis>>);

#[derive(Serialize)]
pub struct Summary {
    root: String,
    size: u64,
    dirs: u64,
    files: u64,
    unreadable: u64,
    /// stopped by the user: sizes only cover what was read
    partial: bool,
    secs: f64,
    /// files of 1 MB or more, largest first
    big: Vec<FileInfo>,
}

/// Own pool with big stacks: the walk recurses once per folder level.
fn pool() -> &'static rayon::ThreadPool {
    static POOL: OnceLock<rayon::ThreadPool> = OnceLock::new();
    POOL.get_or_init(|| {
        rayon::ThreadPoolBuilder::new()
            .stack_size(16 << 20)
            .thread_name(|i| format!("analysis-{i}"))
            .build()
            .expect("analysis thread pool")
    })
}

/// "C:" means the current folder on drive C; the user means its root.
fn normalize(root: &str) -> PathBuf {
    let r = root.trim();
    if r.len() == 2 && r.ends_with(':') {
        PathBuf::from(format!("{r}\\"))
    } else {
        PathBuf::from(r)
    }
}

#[tauri::command]
pub async fn start_analysis(
    root: String,
    jobs: tauri::State<'_, Arc<Jobs>>,
    store: tauri::State<'_, Arc<Store>>,
) -> Result<Summary, String> {
    let (jobs, store) = (jobs.inner().clone(), store.inner().clone());
    tauri::async_runtime::spawn_blocking(move || {
        let root = normalize(&root);
        if !root.is_dir() {
            return Err(format!("Not a folder: {}", root.display()));
        }
        let p = &jobs.analysis;
        let Some(_running) = p.start() else { return Err("A scan is already running".into()) };
        let start = Instant::now();
        let ctx = Ctx { progress: p, big: Mutex::new(Vec::new()), unreadable: AtomicU64::new(0) };
        let name = root.to_string_lossy().into();
        p.total.store(PROGRESS_TOTAL, Relaxed);
        let tree = pool().install(|| build(&root, name, &ctx, 0, PROGRESS_TOTAL));
        let mut big = ctx.big.into_inner().unwrap();
        big.sort_by(|a, b| b.size.cmp(&a.size));
        let summary = Summary {
            root: root.to_string_lossy().into_owned(),
            size: tree.size,
            dirs: p.dirs.load(Relaxed),
            files: p.files.load(Relaxed),
            unreadable: ctx.unreadable.load(Relaxed),
            partial: p.cancelled(),
            secs: start.elapsed().as_secs_f64(),
            big: big.clone(),
        };
        *store.0.lock().unwrap() = Some(Analysis { root, tree, files: big });
        Ok(summary)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[derive(Serialize)]
pub struct Entry {
    name: String,
    path: String,
    size: u64,
    is_dir: bool,
    /// seconds since the Unix epoch; for a folder, its newest file
    modified: u64,
    /// one more level, only when asked for (the Home treemap)
    #[serde(skip_serializing_if = "Vec::is_empty")]
    children: Vec<Entry>,
}

/// Folders of `node` (sizes from the analysis) and the files directly in `dir`,
/// largest first. Files are listed fresh: one folder is cheap, and keeping
/// every file of the scan would cost hundreds of MB.
fn entries(node: &Node, dir: &Path) -> Vec<Entry> {
    let mut out: Vec<Entry> = node
        .children
        .iter()
        .map(|c| Entry {
            name: c.name.to_string(),
            path: dir.join(&*c.name).to_string_lossy().into_owned(),
            size: c.size,
            is_dir: true,
            modified: c.modified,
            children: Vec::new(),
        })
        .collect();
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            let Ok(m) = e.metadata() else { continue };
            if m.file_type().is_file() {
                out.push(Entry {
                    name: e.file_name().to_string_lossy().into_owned(),
                    path: e.path().to_string_lossy().into_owned(),
                    size: m.len(),
                    is_dir: false,
                    modified: crate::files::mtime(&m),
                    children: Vec::new(),
                });
            }
        }
    }
    out.sort_by(|a, b| b.size.cmp(&a.size));
    out
}

/// What is directly inside `path`; with `nested`, also what is inside each of
/// its folders.
#[tauri::command]
pub async fn tree_children(
    path: String,
    nested: Option<bool>,
    store: tauri::State<'_, Arc<Store>>,
) -> Result<Vec<Entry>, String> {
    let store = store.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let dir = PathBuf::from(&path);
        let guard = store.0.lock().unwrap();
        let a = guard.as_ref().ok_or("Nothing scanned yet")?;
        let node = a.find(&dir).ok_or_else(|| format!("Not in the last scan: {path}"))?;
        let mut out = entries(node, &dir);
        if nested.unwrap_or(false) {
            out.par_iter_mut().filter(|e| e.is_dir).for_each(|e| {
                let p = PathBuf::from(&e.path);
                if let Some(n) = node.children.iter().find(|c| *c.name == *e.name) {
                    e.children = entries(n, &p);
                }
            });
        }
        Ok(out)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[derive(Serialize)]
pub struct Info {
    size: u64,
    modified: u64,
    /// size of the folder above, within the scan (None for the scanned root)
    parent_size: Option<u64>,
}

/// Size and newest file of one folder of the last analysis.
#[tauri::command]
pub fn tree_info(path: String, store: tauri::State<'_, Arc<Store>>) -> Result<Info, String> {
    let guard = store.0.lock().unwrap();
    let a = guard.as_ref().ok_or("Nothing scanned yet")?;
    let dir = PathBuf::from(&path);
    let node = a.find(&dir).ok_or_else(|| format!("Not in the last scan: {path}"))?;
    let parent_size = if dir == a.root { None } else { dir.parent().and_then(|p| a.find(p)).map(|n| n.size) };
    Ok(Info { size: node.size, modified: node.modified, parent_size })
}

// ---------- volume ----------

#[derive(Serialize)]
pub struct DiskInfo {
    name: String,
    total: u64,
    free: u64,
}

/// The volume that holds `path` (longest matching mount point).
#[tauri::command]
pub fn disk_info(path: String) -> Option<DiskInfo> {
    let disks = sysinfo::Disks::new_with_refreshed_list().ok()?;
    let p = Path::new(&path);
    (&disks)
        .into_iter()
        .filter(|d| p.starts_with(d.mount_point()))
        .max_by_key(|d| d.mount_point().as_os_str().len())
        .map(|d| {
            let mp = d.mount_point().to_string_lossy().into_owned();
            let label = d.name().to_string_lossy().into_owned();
            DiskInfo {
                name: if cfg!(windows) {
                    let drive = mp.trim_end_matches('\\');
                    if label.is_empty() { format!("Local Disk ({drive})") } else { format!("{label} ({drive})") }
                } else if label.is_empty() { mp } else { label },
                total: d.total_space(),
                free: d.available_space(),
            }
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tree_sizes_and_forget() {
        let dir = std::env::temp_dir().join(format!("cleanbro-tree-{}", std::process::id()));
        let sub = dir.join("a").join("b");
        fs::create_dir_all(&sub).unwrap();
        fs::write(dir.join("small.txt"), b"hello").unwrap();
        fs::write(sub.join("big.bin"), vec![1u8; (BIG + 10) as usize]).unwrap();

        let p = Progress::default();
        let _r = p.start().unwrap();
        let ctx = Ctx { progress: &p, big: Mutex::new(Vec::new()), unreadable: AtomicU64::new(0) };
        let tree = build(&dir, "root".into(), &ctx, 0, PROGRESS_TOTAL);
        assert_eq!(p.done.load(Relaxed), PROGRESS_TOTAL);
        let files = ctx.big.into_inner().unwrap();
        assert_eq!(tree.size, BIG + 15);
        assert_eq!(files.len(), 1);
        assert_eq!(p.files.load(Relaxed), 2);

        let mut a = Analysis { root: dir.clone(), tree, files };
        assert_eq!(a.find(&dir.join("a")).unwrap().size, BIG + 10);
        let big = sub.join("big.bin");
        let (size, is_dir) = a.size_of(&big);
        assert_eq!((size, is_dir), (BIG + 10, false));
        a.forget(&[(big.to_string_lossy().into_owned(), size, is_dir)]);
        assert!(a.files.is_empty());
        assert_eq!(a.tree.size, 5);
        assert_eq!(a.find(&sub).unwrap().size, 0);

        let small = dir.join("small.txt");
        let (size, is_dir) = a.size_of(&small);
        a.forget(&[(small.to_string_lossy().into_owned(), size, is_dir)]);
        assert_eq!(a.tree.size, 0);

        let folder = dir.join("a");
        assert_eq!(a.size_of(&folder), (0, true));
        a.forget(&[(folder.to_string_lossy().into_owned(), 0, true)]);
        assert!(a.find(&folder).is_none());
        fs::remove_dir_all(&dir).ok();
    }
}
