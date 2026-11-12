mod advice;
mod cleanup;
mod files;
mod jobs;
#[cfg(windows)]
mod registry;
mod scan;
mod snapshot;
mod uninstall;

use std::sync::Arc;
use tauri::Manager;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Arc::new(jobs::Jobs::default()))
        .manage(Arc::new(scan::Store::default()))
        .setup(|app| {
            // the last scan is kept next to the other local app data
            if let Ok(dir) = app.path().app_local_data_dir() {
                snapshot::init(dir);
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            jobs::job_progress,
            jobs::cancel_job,
            scan::home_dir,
            scan::disk_info,
            scan::start_analysis,
            scan::load_analysis,
            scan::tree_children,
            scan::tree_info,
            cleanup::scan_junk,
            cleanup::clean_junk,
            uninstall::list_apps,
            uninstall::app_leftovers,
            uninstall::reveal_app,
            uninstall::run_uninstall,
            uninstall::delete_leftovers,
            files::find_dupes,
            files::trash_paths,
            files::reveal,
        ])
        .run(tauri::generate_context!())
        .expect("error while running CleanBro");
}
