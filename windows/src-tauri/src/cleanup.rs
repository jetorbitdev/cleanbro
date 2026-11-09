//! Cleanup: junk that is safe to delete. Each direct child of a junk root is
//! one item. The frontend only sends back paths; `clean_junk` re-derives the
//! allowed roots and refuses anything that is not a direct child of one.

use rayon::prelude::*;
use serde::Serialize;
use std::path::{Component, Path, PathBuf};

const RECYCLE: &str = "recycle-bin:";

struct Def {
    id: &'static str,
    roots: Vec<PathBuf>,
    /// only children with one of these extensions (lowercase)
    exts: Option<&'static [&'static str]>,
}

fn env_path(k: &str) -> Option<PathBuf> {
    std::env::var_os(k).map(PathBuf::from).filter(|p| !p.as_os_str().is_empty())
}

fn defs() -> Vec<Def> {
    let home = env_path("USERPROFILE").or_else(|| env_path("HOME"));
    let local = env_path("LOCALAPPDATA");
    let temp = std::env::temp_dir();
    let h = |s: &str| home.as_ref().map(|p| p.join(s));
    let l = |s: &str| local.as_ref().map(|p| p.join(s));
    let keep = |v: Vec<Option<PathBuf>>| v.into_iter().flatten().collect::<Vec<_>>();

    vec![
        Def {
            id: "temp",
            roots: keep(vec![
                Some(temp),
                env_path("SystemRoot").map(|p| p.join("Temp")),
            ]),
            exts: None,
        },
        Def {
            id: "cache",
            roots: keep(vec![
                l("Google/Chrome/User Data/Default/Cache"),
                l("Google/Chrome/User Data/Default/Code Cache"),
                l("Microsoft/Edge/User Data/Default/Cache"),
                l("Microsoft/Edge/User Data/Default/Code Cache"),
                l("BraveSoftware/Brave-Browser/User Data/Default/Cache"),
                l("Microsoft/Windows/INetCache"),
                l("D3DSCache"),
                l("NVIDIA/DXCache"),
                l("NVIDIA/GLCache"),
            ]),
            exts: None,
        },
        Def {
            id: "logs",
            roots: keep(vec![
                l("CrashDumps"),
                l("Microsoft/Windows/WER/ReportArchive"),
                l("Microsoft/Windows/WER/ReportQueue"),
            ]),
            exts: None,
        },
        Def {
            id: "dev",
            roots: keep(vec![
                l("npm-cache"),
                h(".npm/_cacache"),
                h(".gradle/caches"),
                h(".cache"),
                l("pip/Cache"),
                l("Yarn/Cache"),
            ]),
            exts: None,
        },
        Def {
            id: "dl",
            roots: keep(vec![h("Downloads")]),
            exts: Some(&["crdownload", "part", "partial", "download", "opdownload"]),
        },
    ]
}

#[derive(Serialize)]
pub struct JunkItem {
    path: String,
    name: String,
    size: u64,
}

#[derive(Serialize)]
pub struct JunkCategory {
    id: String,
    /// a folder exists but could not be read
    needs_access: bool,
    items: Vec<JunkItem>,
}

fn matches(d: &Def, p: &Path) -> bool {
    match d.exts {
        None => true,
        Some(exts) => p
            .extension()
            .map(|e| exts.contains(&e.to_string_lossy().to_lowercase().as_str()))
            .unwrap_or(false),
    }
}

#[cfg(windows)]
fn recycle_size() -> u64 {
    use trash::os_limited::{list, metadata};
    use trash::TrashItemSize;
    list()
        .map(|v| {
            v.iter()
                .filter_map(|i| metadata(i).ok())
                .map(|m| match m.size {
                    TrashItemSize::Bytes(b) => b,
                    TrashItemSize::Entries(_) => 0,
                })
                .sum()
        })
        .unwrap_or(0)
}
#[cfg(not(windows))]
fn recycle_size() -> u64 {
    0
}

#[cfg(windows)]
fn empty_recycle() -> Result<(), String> {
    let items = trash::os_limited::list().map_err(|e| e.to_string())?;
    trash::os_limited::purge_all(items).map_err(|e| e.to_string())
}
#[cfg(not(windows))]
fn empty_recycle() -> Result<(), String> {
    Err("Recycle Bin is only available on Windows".into())
}

#[tauri::command]
pub async fn scan_junk() -> Result<Vec<JunkCategory>, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let mut cats = Vec::new();
        for d in defs() {
            let mut unreadable = false;
            let mut cands: Vec<(PathBuf, String)> = Vec::new();
            let multi = d.roots.len() > 1;
            for root in &d.roots {
                if std::fs::symlink_metadata(root).is_err() {
                    continue; // not present
                }
                match std::fs::read_dir(root) {
                    Err(_) => unreadable = true,
                    Ok(rd) => {
                        for e in rd.filter_map(|e| e.ok()) {
                            let p = e.path();
                            if !matches(&d, &p) {
                                continue;
                            }
                            let n = e.file_name().to_string_lossy().into_owned();
                            let label = if multi {
                                let r = root
                                    .file_name()
                                    .map(|s| s.to_string_lossy().into_owned())
                                    .unwrap_or_default();
                                format!("{r}/{n}")
                            } else {
                                n
                            };
                            cands.push((p, label));
                        }
                    }
                }
            }
            let mut items: Vec<JunkItem> = cands
                .into_par_iter()
                .map(|(p, name)| {
                    let size = match std::fs::symlink_metadata(&p) {
                        Ok(m) if m.is_dir() => crate::scan::dir_size(&p),
                        Ok(m) => m.len(),
                        Err(_) => 0,
                    };
                    JunkItem { path: p.to_string_lossy().into_owned(), name, size }
                })
                .filter(|i| i.size > 0)
                .collect();
            items.sort_by(|a, b| b.size.cmp(&a.size));
            cats.push(JunkCategory { id: d.id.into(), needs_access: unreadable, items });
        }
        let rb = recycle_size();
        cats.push(JunkCategory {
            id: "recycle".into(),
            needs_access: false,
            items: if rb > 0 {
                vec![JunkItem { path: RECYCLE.into(), name: "Recycle Bin".into(), size: rb }]
            } else {
                vec![]
            },
        });
        Ok(cats)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[derive(Serialize, Default)]
pub struct CleanResult {
    freed: u64,
    removed: usize,
    failed: Vec<(String, String)>,
}

fn paths_eq(a: &Path, b: &Path) -> bool {
    let n = |p: &Path| {
        p.to_string_lossy().replace('/', "\\").trim_end_matches('\\').to_lowercase()
    };
    if cfg!(windows) { n(a) == n(b) } else { a == b }
}

/// true when `p` is a direct child of an allowed junk root
fn allowed(p: &Path, defs: &[Def]) -> bool {
    if p.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir)) {
        return false;
    }
    let Some(parent) = p.parent() else { return false };
    defs.iter().any(|d| matches(d, p) && d.roots.iter().any(|r| paths_eq(r, parent)))
}

#[tauri::command]
pub async fn clean_junk(paths: Vec<String>) -> Result<CleanResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let defs = defs();
        let mut res = CleanResult::default();
        for s in paths {
            if s == RECYCLE {
                let size = recycle_size();
                match empty_recycle() {
                    Ok(()) => {
                        res.freed += size;
                        res.removed += 1;
                    }
                    Err(e) => res.failed.push((s, e)),
                }
                continue;
            }
            let p = PathBuf::from(&s);
            if !allowed(&p, &defs) {
                res.failed.push((s, "not a cleanup location".into()));
                continue;
            }
            let Ok(md) = std::fs::symlink_metadata(&p) else { continue };
            // remove_dir_all does not follow symlinks
            let (size, r) = if md.is_dir() {
                (crate::scan::dir_size(&p), std::fs::remove_dir_all(&p))
            } else {
                (md.len(), std::fs::remove_file(&p))
            };
            match r {
                Ok(()) => {
                    res.freed += size;
                    res.removed += 1;
                }
                Err(e) => res.failed.push((s, e.to_string())),
            }
        }
        Ok(res)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_paths_outside_junk_roots() {
        let d = defs();
        let temp = std::env::temp_dir();
        assert!(allowed(&temp.join("some-file.tmp"), &d));
        assert!(!allowed(&temp.join("a").join("deep"), &d)); // not a direct child
        assert!(!allowed(&temp.join("..").join("x"), &d));
        assert!(!allowed(Path::new("/"), &d));
        assert!(!allowed(&temp, &d)); // the root itself
    }

    #[test]
    fn cleans_a_temp_item_and_refuses_others() {
        let dir = std::env::temp_dir().join(format!("cleanbro-junk-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        std::fs::write(dir.join("sub/f.bin"), vec![0u8; 1000]).unwrap();
        // direct child of the temp root is allowed, its content is not listed separately
        let outside = std::env::current_dir().unwrap();
        let r = tauri::async_runtime::block_on(clean_junk(vec![
            dir.to_string_lossy().into_owned(),
            outside.to_string_lossy().into_owned(),
        ]))
        .unwrap();
        assert_eq!(r.removed, 1);
        assert_eq!(r.freed, 1000);
        assert_eq!(r.failed.len(), 1);
        assert!(!dir.exists());
        assert!(outside.exists());
    }
}
