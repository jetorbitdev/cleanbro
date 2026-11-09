mod cleanup;
mod files;
#[cfg(windows)]
mod registry;
mod scan;
mod uninstall;

pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            scan::scan_dir,
            scan::home_dir,
            scan::disk_info,
            cleanup::scan_junk,
            cleanup::clean_junk,
            uninstall::list_apps,
            uninstall::app_leftovers,
            uninstall::run_uninstall,
            uninstall::delete_leftovers,
            files::scan_files,
            files::find_dupes,
            files::trash_paths,
        ])
        .run(tauri::generate_context!())
        .expect("error while running CleanBro");
}
