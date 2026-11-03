import Foundation
import Darwin
import CryptoKit

// MARK: - Data

/// Files with byte-identical content. `items` are sorted oldest first.
struct DupeGroup: Identifiable {
    let id: String
    /// logical size of one copy
    let size: Int64
    var items: [Item]

    /// space freed when every copy but one is removed
    var wasted: Int64 {
        items.reduce(0) { $0 + $1.size } - (items.map(\.size).max() ?? 0)
    }
}

// MARK: - Finder

/// Finds duplicates among the files kept by the analysis scan (≥ 1 MB).
/// Candidates are narrowed in three passes so that only files that really
/// might be equal are read completely: same size → same head and tail
/// → same SHA-256 of the whole content.
enum DupeFinder {
    /// Head/tail sample read in the quick pass.
    private static let sample = 64 << 10
    private static let chunk = 1 << 20

    /// Folders whose contents belong to an app or a library database;
    /// removing a "duplicate" from inside them breaks the owner.
    private static let packageExts: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "appex", "xpc",
        "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "fcpbundle", "logicx", "band", "xcarchive", "lrdata", "aplibrary",
    ]
    private static let skippedDirs: Set<String> = ["node_modules", ".git", ".svn", ".hg"]

    static func isProtectedLocation(_ path: String, root: String) -> Bool {
        let h = NSHomeDirectory()
        for prefix in [h + "/Library/", "/Library/", "/System/", "/private/", "/usr/", "/opt/"]
        where path.hasPrefix(prefix) && !(root + "/").hasPrefix(prefix) {
            return true
        }
        for comp in path.split(separator: "/").dropLast() {
            if skippedDirs.contains(String(comp)) { return true }
            if let dot = comp.lastIndex(of: "."),
               packageExts.contains(comp[comp.index(after: dot)...].lowercased()) {
                return true
            }
        }
        return false
    }

    static func find(_ files: [FileEntry], root: String, skipProtected: Bool,
                     progress: ScanProgress) -> [DupeGroup] {
        // 1. group by logical size (allocated size can differ for equal content)
        struct Cand { let entry: FileEntry; let size: Int64 }
        var bySize: [Int64: [Cand]] = [:]
        for f in files {
            if skipProtected && isProtectedLocation(f.path, root: root) { continue }
            var st = stat()
            guard lstat(f.path, &st) == 0, FS.isReg(st), st.st_size > 0 else { continue }
            bySize[Int64(st.st_size), default: []].append(Cand(entry: f, size: Int64(st.st_size)))
        }
        let quick = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        progress.setTotal(quick.count)

        // 2. head + tail
        let quickKeys = hashAll(quick.map { ($0.entry.path, $0.size) }, full: false, progress: progress)
        var byQuick: [Key: [Cand]] = [:]
        for (i, c) in quick.enumerated() {
            if let k = quickKeys[i] { byQuick[k, default: []].append(c) }
        }
        // files no bigger than head + tail were read completely already
        var groups: [Key: [Cand]] = [:]
        var full: [Cand] = []
        for (k, g) in byQuick where g.count > 1 {
            if k.size <= 2 * Int64(sample) { groups[k] = g } else { full.append(contentsOf: g) }
        }
        if progress.isCancelled { return [] }

        // 3. whole content
        progress.setTotal(quick.count + full.count)
        let fullKeys = hashAll(full.map { ($0.entry.path, $0.size) }, full: true, progress: progress)
        for (i, c) in full.enumerated() {
            if let k = fullKeys[i] { groups[k, default: []].append(c) }
        }

        return groups.compactMap { key, cands in
            guard cands.count > 1 else { return nil }
            let items = cands.map { Item($0.entry) }.sorted { $0.modified < $1.modified }
            let id = key.digest.prefix(12).map { String(format: "%02x", $0) }.joined()
            return DupeGroup(id: "\(key.size)-\(id)", size: key.size, items: items)
        }
        .sorted { $0.wasted > $1.wasted }
    }

    private struct Key: Hashable { let size: Int64; let digest: Data }

    private static func hashAll(_ targets: [(path: String, size: Int64)], full: Bool,
                                progress: ScanProgress) -> [Key?] {
        var out = [Key?](repeating: nil, count: targets.count)
        out.withUnsafeMutableBufferPointer { buf in
            let b = buf
            DispatchQueue.concurrentPerform(iterations: targets.count) { i in
                if progress.isCancelled { return }
                let t = targets[i]
                if let d = digest(t.path, size: t.size, full: full, progress: progress) {
                    b[i] = Key(size: t.size, digest: d)
                }
                progress.step(t.path)
            }
        }
        return out
    }

    /// SHA-256 of the whole file, or of its first and last `sample` bytes.
    private static func digest(_ path: String, size: Int64, full: Bool, progress: ScanProgress) -> Data? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { progress.error(); return nil }
        defer { close(fd) }
        // don't push the user's working set out of the page cache
        _ = fcntl(fd, F_NOCACHE, 1)

        var h = SHA256()
        var buf = [UInt8](repeating: 0, count: full ? chunk : sample)

        func read(at offset: off_t, _ count: Int) -> Bool {
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, offset) }
            guard n >= 0 else { progress.error(); return false }
            buf.withUnsafeBytes { h.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            progress.read(Int64(n))
            return true
        }

        if full {
            var offset: off_t = 0
            while offset < size {
                if progress.isCancelled { return nil }
                let want = Int(min(Int64(chunk), size - offset))
                let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, offset) }
                if n < 0 { progress.error(); return nil }
                if n == 0 { break }   // file shrank while reading
                buf.withUnsafeBytes { h.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                progress.read(Int64(n))
                offset += off_t(n)
            }
            guard offset == size else { return nil }
        } else {
            guard read(at: 0, Int(min(Int64(sample), size))) else { return nil }
            if size > Int64(sample) {
                let tail = Int(min(Int64(sample), size - Int64(sample)))
                guard read(at: off_t(size) - off_t(tail), tail) else { return nil }
            }
        }
        return Data(h.finalize())
    }
}
