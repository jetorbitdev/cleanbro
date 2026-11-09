//! Reads the Windows "Uninstall" registry keys. Only compiled on Windows.

use winreg::enums::*;
use winreg::{HKEY, RegKey};

const PATH: &str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";

pub struct RawApp {
    /// `<hive>\<view>\<subkey>`, stable between calls
    pub id: String,
    pub name: String,
    pub version: String,
    pub publisher: String,
    pub install_location: String,
    pub uninstall_string: String,
    pub quiet_uninstall_string: String,
    /// bytes, 0 when the app does not report it
    pub size: u64,
}

fn s(k: &RegKey, name: &str) -> String {
    k.get_value::<String, _>(name).unwrap_or_default().trim().to_string()
}

pub fn read_all() -> Vec<RawApp> {
    let sources: [(&str, HKEY, u32); 3] = [
        ("HKLM", HKEY_LOCAL_MACHINE, KEY_WOW64_64KEY),
        ("HKLM32", HKEY_LOCAL_MACHINE, KEY_WOW64_32KEY),
        ("HKCU", HKEY_CURRENT_USER, KEY_WOW64_64KEY),
    ];
    let mut out = Vec::new();
    for (label, hive, view) in sources {
        let Ok(root) = RegKey::predef(hive).open_subkey_with_flags(PATH, KEY_READ | view) else {
            continue;
        };
        for sub in root.enum_keys().filter_map(|k| k.ok()) {
            let Ok(k) = root.open_subkey_with_flags(&sub, KEY_READ) else { continue };
            let name = s(&k, "DisplayName");
            let uninstall = s(&k, "UninstallString");
            let quiet = s(&k, "QuietUninstallString");
            if name.is_empty() || (uninstall.is_empty() && quiet.is_empty()) {
                continue;
            }
            // system components, hotfixes and sub-entries of another product
            if k.get_value::<u32, _>("SystemComponent").unwrap_or(0) == 1 {
                continue;
            }
            if !s(&k, "ParentKeyName").is_empty() || !s(&k, "ParentDisplayName").is_empty() {
                continue;
            }
            let release = s(&k, "ReleaseType").to_lowercase();
            if matches!(release.as_str(), "update" | "hotfix" | "security update" | "update rollup") {
                continue;
            }
            out.push(RawApp {
                id: format!("{label}\\{sub}"),
                name,
                version: s(&k, "DisplayVersion"),
                publisher: s(&k, "Publisher"),
                install_location: s(&k, "InstallLocation").trim_matches('"').to_string(),
                uninstall_string: uninstall,
                quiet_uninstall_string: quiet,
                size: k.get_value::<u32, _>("EstimatedSize").unwrap_or(0) as u64 * 1024,
            });
        }
    }
    out
}
