//! Disk Usage: size of each direct child of a folder, computed in parallel.

use jwalk::WalkDir;
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Serialize)]
pub struct Entry {
    name: String,
    path: String,
    size: u64,
    is_dir: bool,
}

#[tauri::command]
pub fn home_dir() -> String {
    std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_default()
}

pub(crate) fn dir_size(p: &Path) -> u64 {
    WalkDir::new(p)
        .skip_hidden(false)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter_map(|e| e.metadata().ok())
        .map(|m| m.len())
        .sum()
}

#[tauri::command]
pub async fn scan_dir(path: String) -> Result<Vec<Entry>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let rd = std::fs::read_dir(&path).map_err(|e| e.to_string())?;
        let mut out: Vec<Entry> = rd
            .filter_map(|e| e.ok())
            .map(|e| {
                let p: PathBuf = e.path();
                let ft = e.file_type().ok();
                let is_dir = ft.map(|t| t.is_dir()).unwrap_or(false);
                let is_link = ft.map(|t| t.is_symlink()).unwrap_or(false);
                let size = if is_dir && !is_link {
                    dir_size(&p)
                } else {
                    e.metadata().map(|m| m.len()).unwrap_or(0)
                };
                Entry {
                    name: e.file_name().to_string_lossy().into_owned(),
                    path: p.to_string_lossy().into_owned(),
                    size,
                    is_dir,
                }
            })
            .collect();
        out.sort_by(|a, b| b.size.cmp(&a.size));
        Ok(out)
    })
    .await
    .map_err(|e| e.to_string())?
}

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
