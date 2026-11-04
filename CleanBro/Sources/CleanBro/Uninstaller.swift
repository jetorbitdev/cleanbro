import Foundation
import AppKit

// MARK: - Data

/// An app bundle, or a vendor folder in /Applications holding one or more apps
/// (e.g. "Adobe Creative Cloud").
struct InstalledApp: Identifiable, Hashable {
    let path: String
    let name: String
    /// bundle identifiers of every .app inside (empty when the bundles are already gone)
    let bundleIDs: [String]
    var size: Int64 = 0
    var id: String { path }

    var isFolder: Bool { !path.hasSuffix(".app") }
    var location: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
}

/// Something the uninstall would remove: the app itself or a file it left behind.
struct UninstallItem: Identifiable, Hashable {
    enum Match { case app, sure, maybe }

    let path: String
    let size: Int64
    /// owned by root / in a folder the user can't write: removed with an admin password
    let needsAdmin: Bool
    let match: Match
    var id: String { path }

    /// "Application Support", "Launch Daemon", …
    var kind: String {
        if match == .app { return L("App", "Aplikasi") }
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        switch parent {
        case "LaunchAgents": return "Launch Agent"
        case "LaunchDaemons": return "Launch Daemon"
        case "PrivilegedHelperTools": return "Helper"
        default: return parent
        }
    }
}

// MARK: - Uninstaller

enum AppUninstaller {
    private static let home = NSHomeDirectory()

    static var appFolders: [String] { ["/Applications", "/Applications/Utilities", home + "/Applications"] }

    /// Folders whose direct children may belong to an app.
    private static var leftoverFolders: [String] {
        let user = ["Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers",
                    "Group Containers", "Saved Application State", "HTTPStorages", "WebKit", "Logs",
                    "LaunchAgents", "Cookies", "Application Scripts"].map { home + "/Library/" + $0 }
        let system = ["Application Support", "Caches", "Preferences", "LaunchAgents", "LaunchDaemons",
                      "PrivilegedHelperTools", "Logs"].map { "/Library/" + $0 }
        return user + system
    }

    /// True when `path` can be an uninstall target: an app or vendor folder inside an
    /// Applications folder, or a direct child of one of the leftover folders.
    static func isAllowedTarget(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let parent = (p as NSString).deletingLastPathComponent
        if DeepCleaner.isProtected(p) { return false }
        if appFolders.contains(where: { p.hasPrefix($0 + "/") }) { return p != "/Applications/Utilities" }
        return leftoverFolders.contains(parent)
    }

    // MARK: listing

    /// Apps and vendor folders in the Applications folders (Apple's own apps excluded).
    static func installedApps() -> [InstalledApp] {
        var out: [InstalledApp] = []
        for dir in appFolders {
            for n in FS.list(dir) ?? [] where !n.hasPrefix(".") {
                let p = FS.join(dir, n)
                if p == "/Applications/Utilities" { continue }
                if let app = inspect(p) { out.append(app) }
            }
        }
        out.withUnsafeMutableBufferPointer { buf in
            let b = buf     // each index is written by one worker only
            DispatchQueue.concurrentPerform(iterations: b.count) { i in b[i].size = FS.usage(b[i].path).size }
        }
        return out
    }

    /// Describes `path` as an uninstallable app, or nil for plain files, symlinks and Apple apps.
    static func inspect(_ path: String) -> InstalledApp? {
        var st = stat()
        guard lstat(path, &st) == 0, FS.isDir(st) else { return nil }
        let file = (path as NSString).lastPathComponent
        if path.hasSuffix(".app") {
            let id = bundleID(path)
            if id?.hasPrefix("com.apple.") == true { return nil }
            return InstalledApp(path: path, name: (file as NSString).deletingPathExtension, bundleIDs: id.map { [$0] } ?? [])
        }
        let ids = appsInside(path, depth: 0).compactMap(bundleID)
        if ids.contains(where: { $0.hasPrefix("com.apple.") }) { return nil }
        let name = file.hasSuffix(".localized") ? (file as NSString).deletingPathExtension : file
        return InstalledApp(path: path, name: name, bundleIDs: ids)
    }

    private static func bundleID(_ app: String) -> String? {
        Bundle(path: app)?.bundleIdentifier
    }

    private static func appsInside(_ dir: String, depth: Int) -> [String] {
        guard depth < 4 else { return [] }
        var out: [String] = []
        for n in FS.list(dir) ?? [] {
            let p = FS.join(dir, n)
            var st = stat()
            guard lstat(p, &st) == 0, FS.isDir(st) else { continue }
            if n.hasSuffix(".app") { out.append(p) } else { out += appsInside(p, depth: depth + 1) }
        }
        return out
    }

    /// The vendor's own uninstaller ("Creative Cloud Uninstaller.app", …), if it ships one.
    static func officialUninstaller(for app: InstalledApp) -> String? {
        let search = app.isFolder ? appsInside(app.path, depth: 0)
            : appsInside((app.path as NSString).deletingLastPathComponent, depth: 3)  // siblings only
        return search.first { p in
            let n = (p as NSString).lastPathComponent.lowercased()
            return n.contains("uninstall") && p != app.path
        }
    }

    // MARK: leftovers

    /// The app itself plus every file it left in ~/Library and /Library.
    static func items(for app: InstalledApp) -> [UninstallItem] {
        var out = [UninstallItem(path: app.path, size: app.size, needsAdmin: needsAdmin(app.path), match: .app)]

        var ids = Set(app.bundleIDs.map { $0.lowercased() })
        var names: Set<String> = [app.name.lowercased()]
        for b in app.isFolder ? appsInside(app.path, depth: 0) : [app.path] {
            names.insert(((b as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased())
            if let n = Bundle(path: b)?.object(forInfoDictionaryKey: "CFBundleName") as? String { names.insert(n.lowercased()) }
        }
        names = names.filter { $0.count >= 4 }
        // launchd jobs that start something inside the app: their labels name the app too,
        // which matters when the bundles themselves are already gone
        for dir in leftoverFolders where dir.hasSuffix("/LaunchAgents") || dir.hasSuffix("/LaunchDaemons") {
            for n in FS.list(dir) ?? [] {
                let p = FS.join(dir, n)
                if let prog = launchProgram(p), prog.hasPrefix(app.path + "/"),
                   let label = NSDictionary(contentsOfFile: p)?["Label"] as? String, !label.hasPrefix("com.apple.") {
                    ids.insert(label.lowercased())
                }
            }
        }
        // "com.adobe.acc" from "com.adobe.acc.AdobeCreativeCloud": siblings from the same family
        let families = Set(ids.compactMap { id -> String? in
            let parts = id.split(separator: ".")
            return parts.count >= 4 ? parts.prefix(3).joined(separator: ".") : nil
        })
        // "com.adobe": only for vendor folders, and never checked by default
        let vendors = app.isFolder ? Set(ids.map { $0.split(separator: ".").prefix(2).joined(separator: ".") }) : []

        var helpers: [String] = []
        for dir in leftoverFolders {
            for n in FS.list(dir) ?? [] {
                let p = FS.join(dir, n)
                let isLaunchd = dir.hasSuffix("/LaunchAgents") || dir.hasSuffix("/LaunchDaemons")
                var match = classify(n, ids: ids, names: names, families: families, vendors: vendors, appPath: app.path)
                if isLaunchd, let prog = launchProgram(p) {
                    if prog.hasPrefix(app.path + "/") { match = .sure }
                    if match == .sure, prog.hasPrefix("/Library/PrivilegedHelperTools/") { helpers.append(prog) }
                }
                guard let m = match else { continue }
                out.append(UninstallItem(path: p, size: FS.usage(p).size, needsAdmin: needsAdmin(p), match: m))
            }
        }
        // a helper started by one of the app's daemons belongs to the app even if its name doesn't say so
        for h in helpers {
            if let i = out.firstIndex(where: { $0.path == h }) {
                let old = out[i]
                out[i] = UninstallItem(path: old.path, size: old.size, needsAdmin: old.needsAdmin, match: .sure)
            } else if access(h, F_OK) == 0 {
                out.append(UninstallItem(path: h, size: FS.usage(h).size, needsAdmin: needsAdmin(h), match: .sure))
            }
        }
        return out
    }

    private static func classify(_ file: String, ids: Set<String>, names: Set<String>,
                                 families: Set<String>, vendors: Set<String>, appPath: String) -> UninstallItem.Match? {
        var stem = file.lowercased()
        for ext in [".plist", ".savedstate", ".binarycookies"] where stem.hasSuffix(ext) {
            stem = String(stem.dropLast(ext.count))
        }
        func related(to id: String) -> Bool {
            // exact, or a group container "TEAMID.id"
            if stem == id || stem.hasSuffix("." + id) { return true }
            // "id.helper" is the app's own, unless it is the bundle ID of another app
            // ("com.google.chrome.for.testing" is not Google Chrome's)
            return stem.hasPrefix(id + ".") && !belongsToOtherApp(stem, below: id, appPath: appPath)
        }
        if ids.contains(where: related) || names.contains(stem) { return .sure }
        if families.contains(where: related) { return .maybe }
        if vendors.contains(where: { stem.hasPrefix($0 + ".") || stem.contains("." + $0 + ".") }) { return .maybe }
        return nil
    }

    /// True when `stem` ("com.vendor.app.x.y") or an ID between it and `id` is registered
    /// with Launch Services as an app outside `appPath`.
    private static func belongsToOtherApp(_ stem: String, below id: String, appPath: String) -> Bool {
        var candidate = id
        for part in stem.dropFirst(id.count + 1).split(separator: ".") {
            candidate += "." + part
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate),
               url.path != appPath && !url.path.hasPrefix(appPath + "/") {
                return true
            }
        }
        return false
    }

    private static func launchProgram(_ plist: String) -> String? {
        guard let d = NSDictionary(contentsOfFile: plist) else { return nil }
        if let p = d["Program"] as? String { return p }
        return (d["ProgramArguments"] as? [String])?.first
    }

    private static func needsAdmin(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        return st.st_uid != getuid() || access(parent, W_OK) != 0
    }

    // MARK: running processes

    static func running(_ app: InstalledApp) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { r in
            if let id = r.bundleIdentifier, app.bundleIDs.contains(id) { return true }
            guard let p = r.bundleURL?.path else { return false }
            return p == app.path || p.hasPrefix(app.path + "/")
        }
    }

    /// Asks the app's processes to quit and returns those still running after a while.
    /// Never force-quits: an app waiting on "save changes?" would lose the user's work.
    static func quit(_ apps: [NSRunningApplication]) -> [NSRunningApplication] {
        for a in apps { a.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && apps.contains(where: { !$0.isTerminated }) { usleep(100_000) }
        return apps.filter { !$0.isTerminated }
    }

    // MARK: removal

    /// Removes the chosen items. Files the user owns go to the Trash (or are deleted
    /// for `.permanent`); root-owned items are deleted permanently in one admin-authorised
    /// step. A user item that can't be moved to the Trash is reported, not deleted.
    /// Launch agents/daemons are unloaded before their plist goes.
    static func remove(_ items: [UninstallItem], mode: DeleteMode) -> DeleteResult {
        var r = DeleteResult()
        var admin: [UninstallItem] = []
        for it in items {
            guard isAllowedTarget(it.path) else { r.failed.append((it.path, L("Protected", "Dilindungi"))); continue }
            if it.needsAdmin { admin.append(it); continue }
            if isLaunchPlist(it.path) { launchctl(["bootout", "gui/\(getuid())", it.path]) }
            let one = DeepCleaner.delete([(it.path, it.size)], mode: mode)
            if one.failed.isEmpty {
                r.removed += one.removed
                r.freed += one.freed
            } else if mode == .permanent {
                admin.append(it)    // e.g. a root-owned file deep inside a user folder
            } else {
                // the user asked for the Trash: don't fall back to an unrecoverable rm -rf
                r.failed += one.failed.map { ($0.path, L("Couldn't be moved to the Trash (\($0.reason)). Turn on \"Delete permanently\" to remove it with an admin password.",
                                              "Tidak bisa dipindahkan ke Sampah (\($0.reason)). Centang Hapus permanen untuk menghapusnya dengan password admin.")) }
            }
        }
        if !admin.isEmpty { removeAsAdmin(admin, into: &r) }
        return r
    }

    private static func removeAsAdmin(_ items: [UninstallItem], into r: inout DeleteResult) {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var script = ""
        for it in items where isLaunchPlist(it.path) {
            let domain = it.path.contains("/LaunchDaemons/") ? "system" : "gui/\(getuid())"
            script += "/bin/launchctl bootout \(domain) \(q(it.path)) 2>/dev/null; "
        }
        script += "/bin/rm -rf -- " + items.map { q($0.path) }.joined(separator: " ")
        let apple = "do shell script \"" + script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", apple]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        var reason = L("Failed to run", "Gagal dijalankan")
        do {
            try proc.run()
            proc.waitUntilExit()
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if msg.contains("-128") { reason = L("Admin password cancelled", "Password admin dibatalkan") }
            else if !msg.isEmpty { reason = msg.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch {}

        for it in items {
            if access(it.path, F_OK) != 0 {
                r.removed.append(it.path)
                r.freed += it.size
            } else {
                r.failed.append((it.path, reason))
            }
        }
    }

    private static func isLaunchPlist(_ p: String) -> Bool {
        p.hasSuffix(".plist") && (p.contains("/LaunchAgents/") || p.contains("/LaunchDaemons/"))
    }

    private static func launchctl(_ args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }
}
