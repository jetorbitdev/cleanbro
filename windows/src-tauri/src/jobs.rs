//! Live progress and cancellation for the three long scans (analysis, junk,
//! duplicates). The UI polls `job_progress` while a scan runs and calls
//! `cancel_job` for "Stop & Show Results", like the macOS app.

use serde::Serialize;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::sync::Mutex;

#[derive(Default)]
pub struct Progress {
    running: AtomicBool,
    cancel: AtomicBool,
    pub dirs: AtomicU64,
    pub files: AtomicU64,
    pub bytes: AtomicU64,
    /// finished steps out of `total` (junk candidates, files hashed)
    pub done: AtomicU64,
    pub total: AtomicU64,
    current: Mutex<String>,
}

#[derive(Serialize)]
pub struct Snapshot {
    running: bool,
    stopping: bool,
    dirs: u64,
    files: u64,
    bytes: u64,
    done: u64,
    total: u64,
    current: String,
}

/// Marks the job as running until dropped.
pub struct Running<'a>(&'a Progress);
impl Drop for Running<'_> {
    fn drop(&mut self) {
        self.0.running.store(false, Relaxed);
    }
}

impl Progress {
    /// Resets the counters and marks the job as running; `None` if it already runs.
    pub fn start(&self) -> Option<Running<'_>> {
        if self.running.swap(true, Relaxed) {
            return None;
        }
        self.cancel.store(false, Relaxed);
        for c in [&self.dirs, &self.files, &self.bytes, &self.done, &self.total] {
            c.store(0, Relaxed);
        }
        self.current.lock().unwrap().clear();
        Some(Running(self))
    }

    pub fn cancelled(&self) -> bool {
        self.cancel.load(Relaxed)
    }

    /// Best effort: skipped when another thread is updating it.
    pub fn set_current(&self, p: &Path) {
        if let Ok(mut c) = self.current.try_lock() {
            c.clear();
            c.push_str(&p.to_string_lossy());
        }
    }

    fn snapshot(&self) -> Snapshot {
        Snapshot {
            running: self.running.load(Relaxed),
            stopping: self.cancel.load(Relaxed),
            dirs: self.dirs.load(Relaxed),
            files: self.files.load(Relaxed),
            bytes: self.bytes.load(Relaxed),
            done: self.done.load(Relaxed),
            total: self.total.load(Relaxed),
            current: self.current.lock().unwrap().clone(),
        }
    }
}

#[derive(Default)]
pub struct Jobs {
    pub analysis: Progress,
    pub junk: Progress,
    pub dupes: Progress,
}

impl Jobs {
    fn get(&self, kind: &str) -> Result<&Progress, String> {
        match kind {
            "analysis" => Ok(&self.analysis),
            "junk" => Ok(&self.junk),
            "dupes" => Ok(&self.dupes),
            _ => Err(format!("unknown job: {kind}")),
        }
    }
}

#[tauri::command]
pub fn job_progress(kind: String, jobs: tauri::State<'_, std::sync::Arc<Jobs>>) -> Result<Snapshot, String> {
    Ok(jobs.get(&kind)?.snapshot())
}

#[tauri::command]
pub fn cancel_job(kind: String, jobs: tauri::State<'_, std::sync::Arc<Jobs>>) -> Result<(), String> {
    let p = jobs.get(&kind)?;
    if p.running.load(Relaxed) {
        p.cancel.store(true, Relaxed);
    }
    Ok(())
}
