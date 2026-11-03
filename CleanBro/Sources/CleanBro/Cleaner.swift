import Foundation
import Darwin

// MARK: - Junk categories

struct JunkItem: Identifiable, Hashable {
    let path: String
    let name: String
    var size: Int64
    var id: String { path }
}

struct JunkCategory: Identifiable {
    let id: String
    let name: String
    let icon: String
    var items: [JunkItem]
    var note: String?

    var size: Int64 { items.reduce(0) { $0 + $1.size } }

    var desc: String {
        if let note { return note }
        if items.isEmpty { return "Sudah bersih" }
        let top = items.prefix(3).map(\.name).joined(separator: ", ")
        let rest = items.count - 3
        return rest > 0 ? "\(top), dan \(rest) lainnya" : top
    }
}

enum JunkScanner {
    private struct Def {
        let id: String, name: String, icon: String
        let roots: [String]
        var match: ((String) -> Bool)? = nil
    }

    private static var defs: [Def] {
        let h = NSHomeDirectory()
        return [
            Def(id: "cache", name: "Cache aplikasi", icon: "shippingbox",
                roots: [h + "/Library/Caches"]),
            Def(id: "logs", name: "Log & laporan crash", icon: "doc.text.magnifyingglass",
                roots: [h + "/Library/Logs"]),
            Def(id: "dev", name: "Data developer", icon: "hammer",
                roots: [h + "/Library/Developer/Xcode/DerivedData",
                        h + "/Library/Developer/Xcode/iOS DeviceSupport",
                        h + "/Library/Developer/CoreSimulator/Caches",
                        h + "/.npm/_cacache",
                        h + "/.gradle/caches",
                        h + "/.cache"]),
            Def(id: "dl", name: "Unduhan tidak lengkap", icon: "arrow.down.circle.dotted",
                roots: [h + "/Downloads"],
                match: { n in
                    let ext = (n as NSString).pathExtension.lowercased()
                    return ["crdownload", "part", "partial", "download", "opdownload"].contains(ext)
                }),
            Def(id: "trash", name: "Isi Sampah", icon: "trash",
                roots: [h + "/.Trash"]),
        ]
    }

    /// Finds deletable items. Each top-level child of a junk root is one item.
    static func scan(progress: ScanProgress) -> [JunkCategory] {
        var cats: [JunkCategory] = []
        var candidates: [(cat: Int, path: String, name: String)] = []

        for def in defs {
            var unreadable = false
            for root in def.roots {
                var st = stat()
                guard lstat(root, &st) == 0 else { continue }
                guard let names = FS.list(root) else { unreadable = true; continue }
                let multi = def.roots.count > 1
                for n in names where n != ".DS_Store" && n != ".localized" {
                    if let m = def.match, !m(n) { continue }
                    let label = multi ? "\((root as NSString).lastPathComponent)/\(n)" : n
                    candidates.append((cats.count, FS.join(root, n), label))
                }
            }
            cats.append(JunkCategory(id: def.id, name: def.name, icon: def.icon, items: [],
                                     note: unreadable ? "Butuh izin Full Disk Access" : nil))
        }

        progress.setTotal(candidates.count)
        // -1 = not (fully) measured; such items are left out of a cancelled scan
        var sizes = [Int64](repeating: -1, count: candidates.count)
        sizes.withUnsafeMutableBufferPointer { buf in
            let b = buf
            DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                if progress.isCancelled { return }
                let size = FS.usage(candidates[i].path, progress: progress).size
                if progress.isCancelled { return }   // stopped midway: size is incomplete
                b[i] = size
                progress.step(candidates[i].path)
            }
        }

        for (i, c) in candidates.enumerated() where sizes[i] > 0 {
            cats[c.cat].items.append(JunkItem(path: c.path, name: c.name, size: sizes[i]))
        }
        for i in cats.indices { cats[i].items.sort { $0.size > $1.size } }
        return cats
    }
}

// MARK: - Deep clean

enum DeleteMode { case permanent, trash }

struct DeleteResult {
    var removed: [String] = []
    var freed: Int64 = 0
    var failed: [(path: String, reason: String)] = []
    /// already in the Trash and left alone by a move-to-Trash (only permanent mode deletes them)
    var kept: [(path: String, size: Int64)] = []
}

enum DeepCleaner {
    /// Paths that are never deleted, no matter what was selected.
    static func isProtected(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let h = NSHomeDirectory()
        let exact: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin",
            "/sbin", "/etc", "/var", "/opt", "/Volumes", "/cores", "/tmp",
            h, h + "/Library", h + "/Documents", h + "/Desktop", h + "/Downloads",
            h + "/Movies", h + "/Music", h + "/Pictures", h + "/Applications", h + "/Public",
            h + "/Library/Caches", h + "/Library/Logs", h + "/.Trash",
        ]
        if exact.contains(p) { return true }
        for prefix in ["/System/", "/usr/", "/bin/", "/sbin/", "/private/var/db/"] where p.hasPrefix(prefix) {
            return true
        }
        return p.split(separator: "/").count < 2
    }

    static func delete(_ targets: [(path: String, size: Int64)], mode: DeleteMode) -> DeleteResult {
        var r = DeleteResult()
        let fm = FileManager.default
        for t in targets {
            if isProtected(t.path) {
                r.failed.append((t.path, "Dilindungi"))
                continue
            }
            if mode == .trash && isInTrash(t.path) {
                // already in the Trash: that is where the user asked it to go, and it
                // must stay recoverable, so it is not deleted here
                r.kept.append(t)
                continue
            }
            do {
                switch mode {
                case .trash:
                    try fm.trashItem(at: URL(fileURLWithPath: t.path), resultingItemURL: nil)
                case .permanent:
                    try deepRemove(t.path)
                }
                r.removed.append(t.path)
                r.freed += t.size
            } catch {
                // the folder may be partially gone; count what was actually freed
                let left = FS.usage(t.path).size
                if left < t.size { r.freed += t.size - left }
                r.failed.append((t.path, error.localizedDescription))
            }
        }
        return r
    }

    static func isInTrash(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        return p.hasPrefix(NSHomeDirectory() + "/.Trash/") || p.contains("/.Trashes/\(getuid())/")
    }

    /// The user's Trash folders: ~/.Trash plus .Trashes/<uid> on other mounted volumes.
    static func trashFolders() -> [String] {
        var dirs = [NSHomeDirectory() + "/.Trash"]
        for v in FS.list("/Volumes") ?? [] {
            let d = "/Volumes/\(v)/.Trashes/\(getuid())"
            if access(d, F_OK) == 0 { dirs.append(d) }
        }
        return dirs
    }

    /// Everything currently in the Trash with its size, or nil when ~/.Trash
    /// can't be read (usually missing Full Disk Access).
    static func trashContents() -> [(path: String, size: Int64)]? {
        guard FS.list(NSHomeDirectory() + "/.Trash") != nil else { return nil }
        return trashFolders().flatMap { d in
            (FS.list(d) ?? []).map { n in
                let p = FS.join(d, n)
                return (p, FS.usage(p).size)
            }
        }
    }

    /// Permanently removes a file or folder tree. If plain removal fails,
    /// clears immutable flags and restores owner permissions, then retries.
    static func deepRemove(_ path: String) throws {
        let fm = FileManager.default
        do {
            try fm.removeItem(atPath: path)
        } catch {
            unlock(path)
            try fm.removeItem(atPath: path)
        }
    }

    private static func unlock(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if st.st_flags != 0 { lchflags(path, 0) }
        guard FS.isDir(st) else { return }
        chmod(path, (st.st_mode & 0o7777) | S_IRWXU)
        for n in FS.list(path) ?? [] { unlock(FS.join(path, n)) }
    }
}
