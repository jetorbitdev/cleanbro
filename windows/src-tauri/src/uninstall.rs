//! Uninstall Apps. The list comes from the registry; the frontend only ever
//! sends back an app `id`, and leftovers are re-derived on the backend, so a
//! delete request can never name a path we did not offer.

use rayon::prelude::*;
use serde::Serialize;
use std::path::{Path, PathBuf};

#[cfg(windows)]
use crate::registry::{read_all, RawApp};

#[cfg(not(windows))]
pub struct RawApp {
    pub id: String,
    pub name: String,
    pub version: String,
    pub publisher: String,
    pub install_location: String,
    pub uninstall_string: String,
    pub quiet_uninstall_string: String,
    pub size: u64,
}
#[cfg(not(windows))]
fn read_all() -> Vec<RawApp> {
    Vec::new()
}

#[derive(Serialize)]
pub struct AppInfo {
    id: String,
    name: String,
    version: String,
    publisher: String,
    size: u64,
    /// set when the name tells whether the app is needed (a driver, a runtime, ...)
    advice: Option<crate::advice::Advice>,
}

#[derive(Serialize)]
pub struct Leftover {
    path: String,
    name: String,
    /// folder or file kind, shown as a caption ("AppData\\Roaming", ...)
    place: String,
    size: u64,
}

#[derive(Serialize, Default)]
pub struct DelResult {
    freed: u64,
    removed: usize,
    failed: Vec<(String, String)>,
}

/// name, publisher, install folder of every app listed so far. Once an app has
/// been uninstalled its registry entry is gone; leftovers are still derived
/// from what the backend itself recorded, never from the frontend.
type Known = std::collections::HashMap<String, (String, String, String)>;
fn known() -> &'static std::sync::Mutex<Known> {
    static K: std::sync::OnceLock<std::sync::Mutex<Known>> = std::sync::OnceLock::new();
    K.get_or_init(Default::default)
}

fn find(id: &str) -> Option<RawApp> {
    read_all().into_iter().find(|a| a.id == id)
}

/// the app as listed, or what we remember of it after it was uninstalled
fn resolve(id: &str) -> Option<RawApp> {
    find(id).or_else(|| {
        let k = known().lock().ok()?;
        let (name, publisher, install_location) = k.get(id)?.clone();
        Some(RawApp {
            id: id.to_string(),
            name,
            version: String::new(),
            publisher,
            install_location,
            uninstall_string: String::new(),
            quiet_uninstall_string: String::new(),
            size: 0,
        })
    })
}

#[tauri::command]
pub async fn list_apps() -> Vec<AppInfo> {
    tauri::async_runtime::spawn_blocking(|| {
        let raw = read_all();
        if let Ok(mut k) = known().lock() {
            for a in &raw {
                k.insert(a.id.clone(), (a.name.clone(), a.publisher.clone(), a.install_location.clone()));
            }
        }
        let mut apps: Vec<AppInfo> = raw
            .into_iter()
            .map(|a| AppInfo {
                advice: crate::advice::of_app(&a.name, &a.publisher),
                id: a.id,
                name: a.name,
                version: a.version,
                publisher: a.publisher,
                size: a.size,
            })
            .collect();
        apps.sort_by_key(|a| a.name.to_lowercase());
        // the same app can be listed in more than one registry view
        apps.dedup_by(|a, b| a.name == b.name && a.version == b.version);
        apps
    })
    .await
    .unwrap_or_default()
}

/// lowercase, letters and digits only: "Visual Studio Code" == "visual-studio-code"
fn norm(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(|c| c.to_lowercase()).collect()
}

fn env_path(k: &str) -> Option<PathBuf> {
    std::env::var_os(k).map(PathBuf::from).filter(|p| !p.as_os_str().is_empty())
}

fn place_roots() -> Vec<(PathBuf, &'static str)> {
    [
        ("APPDATA", "AppData\\Roaming"),
        ("LOCALAPPDATA", "AppData\\Local"),
        ("ProgramData", "ProgramData"),
    ]
    .into_iter()
    .filter_map(|(k, label)| env_path(k).map(|p| (p, label)))
    .collect()
}

/// Program Files style roots; an install folder is only offered when it sits
/// directly below one of these.
fn install_bases() -> Vec<PathBuf> {
    let mut v = Vec::new();
    for k in ["ProgramFiles", "ProgramFiles(x86)", "ProgramW6432"] {
        if let Some(p) = env_path(k) {
            v.push(p);
        }
    }
    if let Some(l) = env_path("LOCALAPPDATA") {
        v.push(l.join("Programs"));
    }
    v
}

fn same(a: &Path, b: &Path) -> bool {
    let n = |p: &Path| p.to_string_lossy().replace('/', "\\").trim_end_matches('\\').to_lowercase();
    n(a) == n(b)
}

fn child_dirs(p: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(p)
        .map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.path()).collect())
        .unwrap_or_default()
}

fn base_name(p: &Path) -> String {
    p.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Folders an app leaves behind. Only exact name matches are offered:
/// `<root>\<App>` and `<root>\<Publisher>\<App>`, plus the install folder.
fn leftovers_of(app: &RawApp) -> Vec<(PathBuf, &'static str)> {
    let name = norm(&app.name);
    let publisher = norm(&app.publisher);
    if name.chars().count() < 3 || publisher.contains("microsoft") {
        return Vec::new(); // too generic, or part of Windows / Office
    }
    let mut out: Vec<(PathBuf, &'static str)> = Vec::new();

    for (root, label) in place_roots() {
        for d in child_dirs(&root) {
            let n = norm(&base_name(&d));
            if n == name {
                out.push((d, label));
            } else if !publisher.is_empty() && n == publisher {
                // "<Publisher>\<App>": offer the app's folder, never the vendor's
                for sub in child_dirs(&d) {
                    if norm(&base_name(&sub)) == name {
                        out.push((sub, label));
                    }
                }
            }
        }
    }

    if !app.install_location.is_empty() {
        let loc = PathBuf::from(&app.install_location);
        let under_base = install_bases().iter().any(|b| loc.parent().map(|p| same(p, b)).unwrap_or(false));
        if under_base && loc.exists() {
            out.push((loc, "Install folder"));
        }
    }

    out.sort_by(|a, b| a.0.cmp(&b.0));
    out.dedup_by(|a, b| same(&a.0, &b.0));
    out
}

/// `%NAME%` references in a registry string ("%ProgramFiles%\\App\\unins000.exe").
fn expand_env(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(a) = rest.find('%') {
        out.push_str(&rest[..a]);
        let after = &rest[a + 1..];
        match after.find('%').and_then(|b| std::env::var(&after[..b]).ok().map(|v| (b, v))) {
            Some((b, v)) => {
                out.push_str(&v);
                rest = &after[b + 1..];
            }
            None => {
                out.push('%');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// The program path at the start of an uninstall command line:
/// `"C:\\Program Files\\App\\unins000.exe" /SILENT` or an unquoted `C:\\App\\unins000.exe /S`.
fn exe_of(cmd: &str) -> Option<PathBuf> {
    let cmd = expand_env(cmd.trim());
    let path = if let Some(rest) = cmd.strip_prefix('"') {
        rest[..rest.find('"')?].to_string()
    } else {
        let end = cmd.to_lowercase().find(".exe")? + 4;
        cmd[..end].to_string()
    };
    Some(PathBuf::from(path))
}

/// The folder an app is installed in, as far as the registry tells: its
/// `InstallLocation`, else the folder of its uninstaller (not Windows' own,
/// where `msiexec` lives).
fn install_folder(app: &RawApp) -> Option<PathBuf> {
    let loc = expand_env(app.install_location.trim());
    if !loc.is_empty() && Path::new(&loc).is_dir() {
        return Some(PathBuf::from(loc));
    }
    let windir = std::env::var("SystemRoot").or_else(|_| std::env::var("windir")).unwrap_or_default().to_lowercase();
    let in_windows = |dir: &Path| {
        !windir.is_empty() && format!("{}\\", dir.to_string_lossy().to_lowercase()).starts_with(&format!("{windir}\\"))
    };
    [&app.quiet_uninstall_string, &app.uninstall_string]
        .into_iter()
        .filter_map(|c| exe_of(c))
        .filter(|exe| exe.is_file())
        .filter_map(|exe| exe.parent().map(Path::to_path_buf))
        .find(|dir| !in_windows(dir))
}

/// Opens the app's install folder in Explorer. False when the registry doesn't say where it is.
#[tauri::command]
pub async fn reveal_app(id: String) -> bool {
    tauri::async_runtime::spawn_blocking(move || {
        let Some(dir) = resolve(&id).and_then(|a| install_folder(&a)) else { return false };
        std::process::Command::new("explorer").arg(dir).spawn().is_ok()
    })
    .await
    .unwrap_or(false)
}

#[tauri::command]
pub async fn app_leftovers(id: String) -> Vec<Leftover> {
    tauri::async_runtime::spawn_blocking(move || {
        let Some(app) = resolve(&id) else { return Vec::new() };
        let mut v: Vec<Leftover> = leftovers_of(&app)
            .into_par_iter()
            .map(|(p, place)| Leftover {
                size: crate::scan::dir_size(&p),
                name: base_name(&p),
                place: place.to_string(),
                path: p.to_string_lossy().into_owned(),
            })
            .collect();
        v.sort_by(|a, b| b.size.cmp(&a.size));
        v
    })
    .await
    .unwrap_or_default()
}

/// MSI uninstallers are registered as "/I{GUID}" (install); the uninstall switch is "/X".
fn fix_msi(cmd: &str) -> String {
    let low = cmd.to_lowercase();
    if low.contains("msiexec") {
        if let Some(i) = low.find("/i{") {
            let mut s = cmd.to_string();
            s.replace_range(i..i + 2, "/X");
            return s;
        }
    }
    cmd.to_string()
}

#[cfg(windows)]
fn spawn_wait(cmd: &str) -> Result<i32, String> {
    use std::os::windows::process::CommandExt;
    // `cmd /C ""path" args"` keeps the quoting of the registered string intact
    let status = std::process::Command::new("cmd")
        .raw_arg("/C")
        .raw_arg(format!("\"{cmd}\""))
        .status()
        .map_err(|e| e.to_string())?;
    Ok(status.code().unwrap_or(-1))
}
#[cfg(not(windows))]
fn spawn_wait(_cmd: &str) -> Result<i32, String> {
    Err("Uninstalling apps is only available on Windows".into())
}

/// Runs the app's own uninstaller and waits for it. Returns its exit code.
#[tauri::command]
pub async fn run_uninstall(id: String) -> Result<i32, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let app = find(&id).ok_or("App not found. It may already be uninstalled.")?;
        let cmd = if app.uninstall_string.is_empty() { &app.quiet_uninstall_string } else { &app.uninstall_string };
        spawn_wait(&fix_msi(cmd))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn delete_leftovers(id: String, paths: Vec<String>) -> DelResult {
    tauri::async_runtime::spawn_blocking(move || {
        let mut res = DelResult::default();
        let allowed: Vec<PathBuf> = match resolve(&id) {
            Some(app) => leftovers_of(&app).into_iter().map(|(p, _)| p).collect(),
            None => Vec::new(),
        };
        for s in paths {
            let p = PathBuf::from(&s);
            if !allowed.iter().any(|a| same(a, &p)) {
                res.failed.push((s, "not a leftover of this app".into()));
                continue;
            }
            let Ok(md) = std::fs::symlink_metadata(&p) else { continue };
            let (size, r) = if md.is_dir() {
                (crate::scan::dir_size(&p), std::fs::remove_dir_all(&p))
            } else {
                (md.len(), std::fs::remove_file(&p))
            };
            match r {
                Ok(()) => { res.freed += size; res.removed += 1; }
                Err(e) => res.failed.push((s, e.to_string())),
            }
        }
        res
    })
    .await
    .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn msi_install_switch_becomes_uninstall() {
        assert_eq!(fix_msi("MsiExec.exe /I{ABC-123}"), "MsiExec.exe /X{ABC-123}");
        assert_eq!(fix_msi("MsiExec.exe /X{ABC-123}"), "MsiExec.exe /X{ABC-123}");
        assert_eq!(fix_msi("\"C:\\a\\unins000.exe\" /SILENT"), "\"C:\\a\\unins000.exe\" /SILENT");
    }

    #[test]
    fn finds_the_program_in_an_uninstall_command() {
        let p = |s: &str| exe_of(s).map(|p| p.to_string_lossy().into_owned());
        let want = Some(r"C:\Program Files\App One\unins000.exe".to_string());
        assert_eq!(p(r#""C:\Program Files\App One\unins000.exe" /SILENT"#), want);
        assert_eq!(p(r"C:\Program Files\App One\unins000.exe /S"), want);
        assert_eq!(p("MsiExec.exe /X{ABC}").as_deref(), Some("MsiExec.exe"));
        assert_eq!(p(""), None);
        assert_eq!(p("\"unterminated"), None);
        std::env::set_var("CB_TEST_DIR", r"D:\Apps");
        assert_eq!(expand_env(r"%CB_TEST_DIR%\x\u.exe"), r"D:\Apps\x\u.exe");
        assert_eq!(expand_env("100% sure %NOPE_NOT_SET% ok"), "100% sure %NOPE_NOT_SET% ok");
    }

    #[test]
    fn install_folder_prefers_the_registry_location_and_skips_windows() {
        let dir = std::env::temp_dir().join(format!("cleanbro-app-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("unins000.exe");
        std::fs::write(&exe, b"x").unwrap();
        let app = |loc: &str, cmd: &str| RawApp {
            id: "x".into(),
            name: "App".into(),
            version: String::new(),
            publisher: String::new(),
            install_location: loc.into(),
            uninstall_string: cmd.into(),
            quiet_uninstall_string: String::new(),
            size: 0,
        };
        let msi = r"C:\Windows\System32\msiexec.exe /X{ABC}";
        // the folder of the uninstaller when InstallLocation is empty or gone
        assert_eq!(install_folder(&app("", &format!("\"{}\" /S", exe.display()))), Some(dir.clone()));
        assert_eq!(install_folder(&app(r"Z:\gone", &format!("\"{}\" /S", exe.display()))), Some(dir.clone()));
        // InstallLocation wins when it exists
        assert_eq!(install_folder(&app(&dir.to_string_lossy(), msi)), Some(dir.clone()));
        // msiexec lives in Windows: no folder to show
        assert_eq!(install_folder(&app("", msi)), None);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn names_are_compared_loosely() {
        assert_eq!(norm("Visual Studio Code"), norm("visual-studio-code"));
        assert_ne!(norm("Zoom"), norm("Zoom Rooms"));
    }
}
