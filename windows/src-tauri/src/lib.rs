mod scan;

pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![scan::scan_dir, scan::home_dir])
        .run(tauri::generate_context!())
        .expect("error while running CleanBro");
}
