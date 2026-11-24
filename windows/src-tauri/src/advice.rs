//! Advice: how safe an item is to delete, and why. Every file, folder and app
//! the UI lists gets a level and a reason code (the UI holds the wording).
//!
//! The rules are local and fixed: they only look at where an item sits, what
//! it is called and when it last changed. Nothing is read from the file and
//! nothing leaves the PC. They err towards "review": `Safe` is only given to
//! things Windows or an app rebuilds or downloads again on its own.

use serde::Serialize;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    /// rebuilt or downloaded again when needed: nothing is lost
    Safe,
    /// only the user can tell (personal files, app data, unknown)
    Review,
    /// Windows or an installed app depends on it
    Keep,
}

#[derive(Serialize, Clone, Copy, PartialEq, Eq, Debug)]
pub struct Advice {
    pub level: Level,
    /// reason code, worded by the UI (`WHY` in app.js)
    pub why: &'static str,
}

const fn safe(why: &'static str) -> Advice {
    Advice { level: Level::Safe, why }
}
const fn review(why: &'static str) -> Advice {
    Advice { level: Level::Review, why }
}
const fn keep(why: &'static str) -> Advice {
    Advice { level: Level::Keep, why }
}

const DAY: u64 = 86_400;
/// An installer this fresh may not have been run yet.
const NEW_INSTALLER: u64 = 14 * DAY;
const OLD: u64 = 2 * 365 * DAY;

/// The folders the rules are relative to: lowercase, backslashes, no trailing one.
pub struct Env {
    home: String,
    /// the folder that holds every profile (`C:\Users`)
    users: String,
    drive: String,
    /// folders Windows or installed programs own, with the reason
    owned: Vec<(String, &'static str)>,
    pub(crate) now: u64,
}

fn low(p: &str) -> String {
    p.replace('/', "\\").trim_end_matches('\\').to_lowercase()
}

/// true when `p` is below `dir` (not `dir` itself)
fn under(p: &str, dir: &str) -> bool {
    !dir.is_empty() && p.len() > dir.len() && p.starts_with(dir) && p.as_bytes()[dir.len()] == b'\\'
}

impl Env {
    pub fn current() -> Env {
        let var = |k: &str| std::env::var(k).map(|v| low(&v)).unwrap_or_default();
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let drive = Some(var("SystemDrive")).filter(|d| !d.is_empty()).unwrap_or_else(|| "c:".into());
        let windir = Some(var("SystemRoot")).filter(|d| !d.is_empty()).unwrap_or_else(|| format!("{drive}\\windows"));
        Env::new(&var("USERPROFILE"), &drive, &windir, [var("ProgramFiles"), var("ProgramFiles(x86)"), var("ProgramW6432")], &var("ProgramData"), now)
    }

    fn new(home: &str, drive: &str, windir: &str, programs: [String; 3], program_data: &str, now: u64) -> Env {
        let home = low(home);
        let drive = low(drive);
        let mut owned = vec![
            (low(windir), "windows"),
            (format!("{drive}\\recovery"), "windows"),
            (format!("{drive}\\boot"), "windows"),
            (low(program_data), "app-shared"),
        ];
        owned.extend(programs.iter().map(|p| (low(p), "installed-app")));
        owned.retain(|(d, _)| !d.is_empty());
        let users = home.rsplit_once('\\').map(|(up, _)| up.to_string()).unwrap_or_default();
        Env { home, users, drive, owned, now }
    }

    #[cfg(test)]
    pub(crate) fn fake(now: u64) -> Env {
        Env::new(
            r"C:\Users\me",
            "C:",
            r"C:\Windows",
            [r"C:\Program Files".into(), r"C:\Program Files (x86)".into(), String::new()],
            r"C:\ProgramData",
            now,
        )
    }
}

const PARTIAL: &[&str] = &["crdownload", "part", "partial", "download", "opdownload"];
const DUMPS: &[&str] = &["dmp", "mdmp", "hdmp"];
const INSTALLERS: &[&str] = &["exe", "msi", "msix", "msixbundle", "appx", "appxbundle"];
const ARCHIVES: &[&str] = &["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "cab", "iso", "img"];
const VM_DISKS: &[&str] = &["vmdk", "vdi", "vhd", "vhdx", "qcow2"];
const PERSONAL: &[&str] = &[
    "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "mts", // video
    "jpg", "jpeg", "png", "heic", "gif", "tif", "tiff", "psd", "cr2", "cr3", "nef", "arw", "dng", "webp", "bmp", // images
    "mp3", "wav", "aif", "aiff", "flac", "m4a", "aac", "ogg", "wma", // audio
    "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "epub", // documents
];
/// Folders inside AppData that apps fill again on their own.
const CACHE_DIRS: &[&str] = &[
    "cache", "caches", "code cache", "gpucache", "shadercache", "grshadercache", "dawncache", "cachestorage",
    "cacheddata", "inetcache", "d3dscache", "dxcache", "glcache", "tempstate", "temp", "tmp",
];
const CRASH_DIRS: &[&str] = &["crashdumps", "crashpad", "crash reports", "reportarchive", "reportqueue"];
/// Package caches of developer tools, below the home folder.
const DEV_CACHES: &[&str] = &[
    r"\npm-cache", r"\.npm\_cacache", r"\pip\cache", r"\yarn\cache", r"\.gradle\caches", r"\.nuget\packages",
    r"\.cargo\registry", r"\.m2\repository", r"\go\pkg\mod", r"\.pnpm-store", r"\.cache",
];
/// The profile's own folders: what is inside may go, the folder itself stays.
const PROFILE_DIRS: &[&str] = &[
    r"\appdata", r"\appdata\local", r"\appdata\locallow", r"\appdata\roaming", r"\appdata\local\temp",
    r"\desktop", r"\documents", r"\downloads", r"\pictures", r"\music", r"\videos",
];
const CLOUD_DIRS: &[&str] = &["dropbox", "google drive", "icloud drive", "iclouddrive", "owncloud", "nextcloud", "box", "mega"];
/// Keys and sign-in data of command line tools, below the home folder.
const KEY_DIRS: &[&str] = &[".ssh", ".gnupg", ".aws", ".azure", ".kube"];
const PERSONAL_DIRS: &[&str] = &[r"\desktop", r"\documents", r"\pictures", r"\music", r"\videos"];

/// Advice for a file or folder. `modified` is in seconds since the Unix epoch
/// (0 = unknown); for a folder, its newest file.
pub fn of_path(path: &str, is_dir: bool, modified: u64, env: &Env) -> Advice {
    let p = low(path);
    let comps: Vec<&str> = p.split('\\').collect();
    let name = *comps.last().unwrap_or(&"");
    let ext = match name.rsplit_once('.') {
        Some((stem, e)) if !is_dir && !stem.is_empty() => e,
        _ => "",
    };
    let age = if modified == 0 { u64::MAX } else { env.now.saturating_sub(modified) };
    let home = |sub: &str| format!("{}{sub}", env.home);
    // `p` with a trailing separator, so a folder matches a rule about its own name
    let dir = format!("{p}\\");
    let has = |seq: &str| dir.contains(&format!("{seq}\\"));

    // ---- owned by Windows or an installed program ----
    if comps.len() == 1 {
        return keep("windows"); // a drive
    }
    if comps.len() == 2 {
        if matches!(name, "pagefile.sys" | "hiberfil.sys" | "swapfile.sys") {
            return keep("windows");
        }
        if p == format!("{}\\windows.old", env.drive) {
            return review("windows-old");
        }
    }
    if matches!(comps[1], "$recycle.bin" | "system volume information") {
        return keep("windows");
    }
    if under(&p, &format!("{}\\windows.old", env.drive)) {
        return review("windows-old");
    }
    for (owned, why) in &env.owned {
        if p == *owned || under(&p, owned) {
            return keep(why);
        }
    }
    if !env.home.is_empty() {
        if p == env.users || (under(&p, &env.users) && p != env.home && !under(&p, &env.home)) {
            return keep("other-user");
        }
        if p == env.home || PROFILE_DIRS.iter().any(|d| p == home(d)) {
            return keep("profile");
        }
    }
    let in_home = under(&p, &env.home);
    let in_appdata = under(&p, &home(r"\appdata"));
    let home_depth = env.home.split('\\').count();
    // the folder directly below the home folder ("" outside it)
    let top = if in_home { comps[home_depth] } else { "" };
    // the user's registry hives
    if (in_home && comps.len() == home_depth + 1 && name.starts_with("ntuser."))
        || (in_appdata && name.starts_with("usrclass.dat"))
    {
        return keep("windows");
    }
    if KEY_DIRS.contains(&top) {
        return keep("keys");
    }

    // ---- rebuilt or downloaded again on their own ----
    if PARTIAL.contains(&ext) {
        // still being written when it changed within the last day
        return if age < DAY { review("downloading") } else { safe("partial-download") };
    }
    if DUMPS.contains(&ext) {
        return safe("crash-dump");
    }
    // outside Temp, a fresh .tmp may be an unsaved document an app still holds
    if under(&p, &home(r"\appdata\local\temp")) || (matches!(ext, "tmp" | "temp") && age > 7 * DAY) {
        return safe("temp");
    }
    if comps.contains(&"__pycache__") || (in_home && DEV_CACHES.iter().any(|c| has(c))) {
        return safe("dev-cache");
    }
    if in_appdata {
        if comps.iter().any(|c| CRASH_DIRS.contains(c)) {
            return safe("crash-dump");
        }
        if comps.iter().any(|c| CACHE_DIRS.contains(c))
            || (ext == "db" && (name.starts_with("thumbcache_") || name.starts_with("iconcache")))
        {
            return safe("cache");
        }
        // "000020.log" is a database journal (LevelDB), not a log
        let numbered = name.split('.').next().is_some_and(|stem| stem.bytes().all(|b| b.is_ascii_digit()));
        if comps.contains(&"logs") || (matches!(ext, "log" | "etl") && !numbered) {
            return safe("log");
        }
    }
    if INSTALLERS.contains(&ext) && under(&p, &home(r"\downloads")) {
        return if age < NEW_INSTALLER { review("new-installer") } else { safe("installer") };
    }

    // ---- losing these loses work or data ----
    if comps.contains(&".git") {
        return keep("git");
    }
    if matches!(ext, "pst" | "ost") {
        return keep("mailbox");
    }
    if matches!(name, "ext4.vhdx" | "docker_data.vhdx") || (ext == "vhdx" && in_appdata) {
        return keep("wsl-docker");
    }

    // ---- only the user can tell ----
    if VM_DISKS.contains(&ext) {
        return review("vm-disk");
    }
    if top.starts_with("onedrive") || CLOUD_DIRS.contains(&top) {
        return review("cloud");
    }
    // AppData, and the dot folders tools keep in the home folder (.vscode, .bun, ...)
    if in_appdata || (top.starts_with('.') && comps.len() > home_depth + 1) {
        return review("app-data");
    }
    if comps.contains(&"node_modules") {
        return review("node-modules");
    }
    if ARCHIVES.contains(&ext) && under(&p, &home(r"\downloads")) {
        return review("download-archive");
    }
    if PERSONAL.contains(&ext) || PERSONAL_DIRS.iter().any(|d| under(&p, &home(d))) {
        return review("personal");
    }
    if age != u64::MAX && age > OLD {
        return review("old");
    }
    review("unknown")
}

/// Bundled or "PC tune-up" software most people never asked for.
const UNWANTED: &[&str] = &[
    "toolbar", "webadvisor", "wildtangent", "driver booster", "driver easy", "driver updater", "registry cleaner",
    "pc optimizer", "pc cleaner", "pc speed", "mywebsearch", "conduit", "babylon", "amazon assistant",
];
const RUNTIMES: &[&str] = &[
    "redistributable", "visual c++", "vcredist", "runtime", ".net framework", "asp.net core", "webview2", "directx",
    "targeting pack",
];
const HW_VENDORS: &[&str] = &[
    "nvidia", "intel", "advanced micro devices", "amd ", "realtek", "qualcomm", "synaptics", "elan ", "mediatek",
    "broadcom", "conexant",
];
const HW_PARTS: &[&str] = &[
    "graphics", "chipset", "audio", "bluetooth", "wireless", "wi-fi", "wifi", "lan ", "ethernet", "touchpad",
    "card reader", "management engine", "serial io", "rapid storage", "physx",
];

/// Advice for an installed app, when its name says something; None for an
/// ordinary app, which only the user can judge.
pub fn of_app(name: &str, publisher: &str) -> Option<Advice> {
    let n = format!("{} ", name.to_lowercase());
    let who = format!("{n}{} ", publisher.to_lowercase());
    let any = |list: &[&str], s: &str| list.iter().any(|x| s.contains(x));
    if any(UNWANTED, &n) {
        return Some(safe("unwanted"));
    }
    if any(RUNTIMES, &n) {
        return Some(keep("runtime"));
    }
    if n.contains("driver") || (any(HW_VENDORS, &who) && any(HW_PARTS, &n)) {
        return Some(keep("driver"));
    }
    if n.starts_with("microsoft edge ") || n.contains("update health tools") {
        return Some(keep("windows-part"));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_800_000_000;

    fn file(path: &str, age_days: u64) -> (Level, &'static str) {
        let a = of_path(path, false, NOW - age_days * DAY, &Env::fake(NOW));
        (a.level, a.why)
    }
    fn folder(path: &str) -> (Level, &'static str) {
        let a = of_path(path, true, NOW - 30 * DAY, &Env::fake(NOW));
        (a.level, a.why)
    }

    #[test]
    fn windows_and_installed_programs_are_kept() {
        assert_eq!(folder(r"C:\"), (Level::Keep, "windows"));
        assert_eq!(file(r"C:\pagefile.sys", 0), (Level::Keep, "windows"));
        assert_eq!(file(r"C:\Windows\System32\big.dll", 900), (Level::Keep, "windows"));
        // even what looks like junk: the UI can't delete in there
        assert_eq!(file(r"C:\Windows\Temp\x.tmp", 900), (Level::Keep, "windows"));
        assert_eq!(file(r"C:\Program Files (x86)\App\data.bin", 900), (Level::Keep, "installed-app"));
        assert_eq!(folder(r"C:\Program Files"), (Level::Keep, "installed-app"));
        assert_eq!(file(r"C:\ProgramData\App\cache\x.bin", 900), (Level::Keep, "app-shared"));
        assert_eq!(file(r"D:\$RECYCLE.BIN\S-1-5\$R1.zip", 3), (Level::Keep, "windows"));
        assert_eq!(folder(r"C:\Windows.old"), (Level::Review, "windows-old"));
        assert_eq!(file(r"C:\Windows.old\Users\a\b.iso", 3), (Level::Review, "windows-old"));
        // a folder that only starts like an owned one is not owned
        assert_eq!(file(r"C:\Program Files Backup\x.bin", 3), (Level::Review, "unknown"));
    }

    #[test]
    fn profiles_keep_their_skeleton() {
        assert_eq!(folder(r"C:\Users"), (Level::Keep, "other-user"));
        assert_eq!(folder(r"C:\Users\Public"), (Level::Keep, "other-user"));
        assert_eq!(file(r"C:\Users\other\Downloads\setup.exe", 900), (Level::Keep, "other-user"));
        assert_eq!(folder(r"C:\Users\me"), (Level::Keep, "profile"));
        assert_eq!(folder(r"C:\Users\me\AppData\Local"), (Level::Keep, "profile"));
        assert_eq!(folder(r"C:\Users\me\AppData\Local\Temp"), (Level::Keep, "profile"));
        assert_eq!(folder(r"C:\Users\me\Documents\"), (Level::Keep, "profile"));
        assert_eq!(folder(r"C:\Users\me\Documents\Taxes"), (Level::Review, "personal"));
        assert_eq!(file(r"C:\Users\me\NTUSER.DAT", 0), (Level::Keep, "windows"));
        assert_eq!(file(r"C:\Users\me\ntuser.dat.LOG1", 900), (Level::Keep, "windows"));
        assert_eq!(file(r"C:\Users\me\AppData\Local\Microsoft\Windows\UsrClass.dat", 0), (Level::Keep, "windows"));
        assert_eq!(folder(r"C:\Users\me\.ssh"), (Level::Keep, "keys"));
        assert_eq!(file(r"C:\Users\me\.kube\cache\discovery\x.json", 5), (Level::Keep, "keys"));
    }

    #[test]
    fn rebuilt_things_are_safe() {
        assert_eq!(file(r"C:\Users\me\AppData\Local\Temp\a\b.bin", 0), (Level::Safe, "temp"));
        assert_eq!(folder(r"C:\Users\me\AppData\Local\Temp\a"), (Level::Safe, "temp"));
        assert_eq!(file(r"D:\work\~export.TMP", 30), (Level::Safe, "temp"));
        // a fresh one may be an unsaved document
        assert_eq!(file(r"C:\Users\me\AppData\Roaming\Microsoft\PowerPoint\ppt1A0A.tmp", 1), (Level::Review, "app-data"));
        assert_eq!(file(r"C:\Users\me\AppData\Local\Google\Chrome\User Data\Default\Cache\Cache_Data\f_01", 1), (Level::Safe, "cache"));
        assert_eq!(folder(r"C:\Users\me\AppData\Roaming\Code\CachedData"), (Level::Safe, "cache"));
        assert_eq!(file(r"C:\Users\me\AppData\Local\Microsoft\Windows\Explorer\thumbcache_256.db", 1), (Level::Safe, "cache"));
        assert_eq!(file(r"C:\Users\me\AppData\Local\CrashDumps\app.exe.123.dmp", 1), (Level::Safe, "crash-dump"));
        assert_eq!(file(r"D:\games\crash.dmp", 1), (Level::Safe, "crash-dump"));
        assert_eq!(file(r"C:\Users\me\AppData\Roaming\App\logs\main.log", 1), (Level::Safe, "log"));
        assert_eq!(file(r"C:\Users\me\AppData\Local\Adobe\updater.log", 1), (Level::Safe, "log"));
        // a LevelDB journal holds the app's data
        assert_eq!(file(r"C:\Users\me\AppData\Local\Brave\User Data\Default\Extension State\000020.log", 1), (Level::Review, "app-data"));
        assert_eq!(file(r"C:\Users\me\AppData\Local\npm-cache\_cacache\content\ab\cd", 1), (Level::Safe, "dev-cache"));
        assert_eq!(folder(r"C:\Users\me\.gradle\caches"), (Level::Safe, "dev-cache"));
        assert_eq!(file(r"C:\Users\me\.cargo\registry\index\x\.git\objects\pack\p.pack", 1), (Level::Safe, "dev-cache"));
        assert_eq!(file(r"D:\proj\app\__pycache__\m.pyc", 1), (Level::Safe, "dev-cache"));
        // a "cache" folder outside AppData may be anything
        assert_eq!(file(r"D:\proj\cache\model.bin", 1), (Level::Review, "unknown"));
        // real app data that sits next to the caches is not one
        assert_eq!(file(r"C:\Users\me\AppData\Local\Google\Chrome\User Data\Default\History", 1), (Level::Review, "app-data"));
    }

    #[test]
    fn downloads_depend_on_kind_and_age() {
        assert_eq!(file(r"C:\Users\me\Downloads\setup.exe", 60), (Level::Safe, "installer"));
        assert_eq!(file(r"C:\Users\me\Downloads\sub\Setup.MSI", 60), (Level::Safe, "installer"));
        assert_eq!(file(r"C:\Users\me\Downloads\setup.exe", 2), (Level::Review, "new-installer"));
        // unknown date counts as old
        assert_eq!(of_path(r"C:\Users\me\Downloads\setup.exe", false, 0, &Env::fake(NOW)).why, "installer");
        // a program outside Downloads is somebody's program
        assert_eq!(file(r"D:\tools\app.exe", 900), (Level::Review, "old"));
        assert_eq!(file(r"C:\Users\me\Downloads\movie.mkv.crdownload", 9), (Level::Safe, "partial-download"));
        assert_eq!(file(r"C:\Users\me\Downloads\movie.mkv.crdownload", 0), (Level::Review, "downloading"));
        assert_eq!(file(r"C:\Users\me\Downloads\photos.zip", 60), (Level::Review, "download-archive"));
        assert_eq!(file(r"C:\Users\me\Downloads\ubuntu.iso", 60), (Level::Review, "download-archive"));
        assert_eq!(file(r"C:\Users\me\Downloads\holiday.mp4", 60), (Level::Review, "personal"));
    }

    #[test]
    fn data_that_cannot_be_rebuilt_is_not_safe() {
        assert_eq!(file(r"D:\proj\.git\objects\pack\p.pack", 900), (Level::Keep, "git"));
        assert_eq!(folder(r"D:\proj\.git"), (Level::Keep, "git"));
        assert_eq!(file(r"C:\Users\me\Documents\Outlook Files\mail.pst", 900), (Level::Keep, "mailbox"));
        assert_eq!(file(r"C:\Users\me\AppData\Local\Packages\Ubuntu\LocalState\ext4.vhdx", 1), (Level::Keep, "wsl-docker"));
        assert_eq!(file(r"D:\VMs\win11.vmdk", 900), (Level::Review, "vm-disk"));
        assert_eq!(file(r"D:\proj\node_modules\x\big.node", 900), (Level::Review, "node-modules"));
        assert_eq!(file(r"C:\Users\me\OneDrive - Work\Videos\a.mp4", 900), (Level::Review, "cloud"));
        assert_eq!(file(r"C:\Users\me\Dropbox\setup.exe", 900), (Level::Review, "cloud"));
        assert_eq!(file(r"C:\Users\me\ownCloud\Documents\a.png", 900), (Level::Review, "cloud"));
        // inside a tool's own folder, node_modules is part of the tool
        assert_eq!(file(r"C:\Users\me\.vscode\extensions\x\node_modules\big.node", 900), (Level::Review, "app-data"));
        assert_eq!(file(r"C:\Users\me\.bun\bin\bun.exe", 30), (Level::Review, "app-data"));
        assert_eq!(file(r"C:\Users\me\.gitconfig", 30), (Level::Review, "unknown"));
        assert_eq!(file(r"C:\Users\me\AppData\Roaming\App\data.db", 900), (Level::Review, "app-data"));
        assert_eq!(file(r"D:\photos\img.CR3", 900), (Level::Review, "personal"));
        assert_eq!(file(r"C:\Users\me\Desktop\notes.bin", 3), (Level::Review, "personal"));
        assert_eq!(file(r"D:\stuff\data.bin", 800), (Level::Review, "old"));
        assert_eq!(file(r"D:\stuff\data.bin", 30), (Level::Review, "unknown"));
        // forward slashes and a dot file without an extension
        assert_eq!(file("D:/stuff/.dmp", 30), (Level::Review, "unknown"));
    }

    #[test]
    fn apps_are_judged_by_name() {
        let app = |n: &str, p: &str| of_app(n, p).map(|a| (a.level, a.why));
        assert_eq!(app("Microsoft Visual C++ 2015-2022 Redistributable (x64)", "Microsoft Corporation"), Some((Level::Keep, "runtime")));
        assert_eq!(app("Microsoft Windows Desktop Runtime - 8.0.4 (x64)", "Microsoft Corporation"), Some((Level::Keep, "runtime")));
        assert_eq!(app("Microsoft Edge WebView2 Runtime", "Microsoft Corporation"), Some((Level::Keep, "runtime")));
        assert_eq!(app("NVIDIA Graphics Driver 551.23", "NVIDIA Corporation"), Some((Level::Keep, "driver")));
        assert_eq!(app("Realtek High Definition Audio", "Realtek Semiconductor Corp."), Some((Level::Keep, "driver")));
        assert_eq!(app("Intel(R) Wireless Bluetooth(R)", "Intel Corporation"), Some((Level::Keep, "driver")));
        assert_eq!(app("Microsoft Edge", "Microsoft Corporation"), Some((Level::Keep, "windows-part")));
        // a tune-up tool is not a driver, and a vendor's optional app is just an app
        assert_eq!(app("Driver Booster 11", "IObit"), Some((Level::Safe, "unwanted")));
        assert_eq!(app("McAfee WebAdvisor", "McAfee, LLC"), Some((Level::Safe, "unwanted")));
        assert_eq!(app("NVIDIA GeForce Experience", "NVIDIA Corporation"), None);
        assert_eq!(app("Visual Studio Code", "Microsoft Corporation"), None);
        assert_eq!(app("7-Zip 23.01 (x64)", "Igor Pavlov"), None);
        assert_eq!(app("Audacity", "Audacity Team"), None);
    }
}
