mod cleanup;
mod files;
mod jobs;
#[cfg(windows)]
mod registry;
mod scan;
mod uninstall;

use std::sync::Arc;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Arc::new(jobs::Jobs::default()))
        .manage(Arc::new(scan::Store::default()))
        .invoke_handler(tauri::generate_handler![
            jobs::job_progress,
            jobs::cancel_job,
            scan::home_dir,
            scan::disk_info,
            scan::start_analysis,
            scan::tree_children,
            scan::tree_info,
            cleanup::scan_junk,
            cleanup::clean_junk,
            uninstall::list_apps,
            uninstall::app_leftovers,
            uninstall::run_uninstall,
            uninstall::delete_leftovers,
            files::find_dupes,
            files::trash_paths,
            files::reveal,
        ])
        .run(tauri::generate_context!())
        .expect("error while running CleanBro");
}
