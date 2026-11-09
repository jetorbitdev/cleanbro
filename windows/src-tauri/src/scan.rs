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
