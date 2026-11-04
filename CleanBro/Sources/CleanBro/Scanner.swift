import Foundation
import Darwin

// MARK: - Data

/// Why a folder was not scanned.
enum SkipReason: Hashable {
    case cloud, network, user, always

    var label: String {
        switch self {
        case .cloud: "Cloud"
        case .network: L("Network", "Jaringan")
        case .user: L("Skipped", "Dilewati")
        case .always: L("Always skipped", "Selalu dilewati")
        }
    }

    var help: String {
        switch self {
        case .cloud: L("Cloud folders (Google Drive, iCloud, Dropbox…) are skipped: reading them is slow and they often contain only placeholders.",
                       "Folder cloud (Google Drive, iCloud, Dropbox…) dilewati: membacanya lambat dan isinya sering hanya placeholder.")
        case .network: L("Network volumes are skipped: reading them is slow and they don't use this Mac's disk.",
                         "Volume jaringan dilewati: membacanya lambat dan tidak memakai disk Mac ini.")
        case .user: L("Skipped during the scan. Size not calculated yet.", "Dilewati saat pemindaian. Ukuran belum dihitung.")
        case .always: L("On the Always Skip list (Settings). Size not calculated yet.", "Ada di daftar Selalu Lewati (Pengaturan). Ukuran belum dihitung.")
        }
    }
}

/// Directory node of the scanned tree. `modified` is the newest modification
/// time of anything inside it (deep), so an old value means "nothing in here
/// has changed since then".
final class DirNode: Identifiable {
    let path: String
    let name: String
    var size: Int64 = 0
    var fileCount: Int64 = 0
    var modified: Date = .distantPast
    /// false when the scan was stopped before everything inside was counted
    var complete = false
    /// set when the folder was left out (its size is only its own entry)
    var skipped: SkipReason?
    var children: [DirNode] = []
    weak var parent: DirNode?

    var id: String { path }

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

struct FileEntry: Identifiable, Hashable {
    let path: String
    let size: Int64
    let modified: Date
    var id: String { path }
    var parentPath: String { (path as NSString).deletingLastPathComponent }
}

// MARK: - Progress (shared between worker threads and the UI)

final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _files: Int64 = 0
    private var _dirs: Int64 = 0
    private var _bytes: Int64 = 0
    private var _errors: Int64 = 0
    private var _done: Int = 0
    private var _total: Int = 0
    private var _current = ""
    private var _cancelled = false
    /// folders being scanned right now → start time
    private var _active: [String: CFAbsoluteTime] = [:]
    private var _skipped = Set<String>()

    /// A folder that has been busy for at least `slowAfter` seconds.
    struct SlowDir: Hashable { let path: String; let seconds: Int }
    static let slowAfter: CFAbsoluteTime = 5

    struct Snapshot {
        var files: Int64, dirs: Int64, bytes: Int64, errors: Int64
        var done: Int, total: Int
        var current: String
        /// every slow folder, outermost first
        var slow: [SlowDir] = []

        static let zero = Snapshot(files: 0, dirs: 0, bytes: 0, errors: 0, done: 0, total: 0, current: "")

        /// Slow folders with no slow folder inside: where the time actually goes.
        var stuck: [SlowDir] {
            let leaves = slow.filter { s in !slow.contains { $0.path.hasPrefix(s.path + "/") } }
            return Array(leaves.sorted { $0.seconds > $1.seconds }.prefix(3))
        }

        /// `dir` and its slow parents, outermost first (the choices for skipping).
        func chain(_ dir: SlowDir) -> [SlowDir] {
            slow.filter { dir.path == $0.path || dir.path.hasPrefix($0.path + "/") }
        }
    }

    func addDir(path: String, files: Int64, bytes: Int64) {
        lock.lock()
        _dirs += 1; _files += files; _bytes += bytes
        if _dirs % 64 == 1 { _current = path }
        lock.unlock()
    }

    func error() { lock.lock(); _errors += 1; lock.unlock() }
    func read(_ bytes: Int64) { lock.lock(); _bytes += bytes; lock.unlock() }
    func setTotal(_ n: Int) { lock.lock(); _total = n; lock.unlock() }
    func step(_ path: String) { lock.lock(); _done += 1; _current = path; lock.unlock() }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    func enter(_ path: String) { lock.lock(); _active[path] = CFAbsoluteTimeGetCurrent(); lock.unlock() }
    func leave(_ path: String) { lock.lock(); _active[path] = nil; lock.unlock() }

    /// Asks the scanner to leave out `path` and everything below it.
    func skip(_ path: String) { lock.lock(); _skipped.insert(path); lock.unlock() }
    func wasSkipped(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return _skipped.contains(path) }

    /// true when the scan was cancelled or `path` (or a folder above it) was skipped
    func shouldStop(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled || isUnderSkipped(path)
    }

    private func isUnderSkipped(_ path: String) -> Bool {
        !_skipped.isEmpty && _skipped.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        let slow = _active
            .filter { now - $0.value >= Self.slowAfter && !isUnderSkipped($0.key) }
            .map { SlowDir(path: $0.key, seconds: Int(now - $0.value)) }
            .sorted { $0.path.count < $1.path.count }
        return Snapshot(files: _files, dirs: _dirs, bytes: _bytes, errors: _errors,
                        done: _done, total: _total, current: _current, slow: slow)
    }
}

// MARK: - Low level helpers

enum FS {
    static func name(of ent: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &ent.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    static func isDir(_ st: stat) -> Bool { (st.st_mode & S_IFMT) == S_IFDIR }
    static func isReg(_ st: stat) -> Bool { (st.st_mode & S_IFMT) == S_IFREG }
    static func mtime(_ st: stat) -> Date { Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)) }

    /// Lists entry names of a directory (without . and ..). nil if unreadable.
    static func list(_ path: String) -> [String]? {
        guard let d = opendir(path) else { return nil }
        defer { closedir(d) }
        var out: [String] = []
        while let ent = readdir(d) {
            let n = name(of: ent)
            if n != "." && n != ".." { out.append(n) }
        }
        return out
    }

    /// Allocated size on disk (like `du`) of a path, recursive, plus newest mtime.
    static func usage(_ path: String, progress: ScanProgress? = nil) -> (size: Int64, modified: Date) {
        var st = stat()
        guard lstat(path, &st) == 0 else { progress?.error(); return (0, .distantPast) }
        var total = Int64(st.st_blocks) * 512
        var newest = mtime(st)
        if isDir(st) {
            guard let names = list(path) else { progress?.error(); return (total, newest) }
            for n in names {
                if progress?.isCancelled == true { break }
                let r = usage(join(path, n), progress: progress)
                total += r.size
                if r.modified > newest { newest = r.modified }
            }
        }
        return (total, newest)
    }
}

// MARK: - Parallel disk scanner (Swift port of the cleanbro CLI)

final class DiskScanner: @unchecked Sendable {
    let root: String
    let progress: ScanProgress
    /// Files at least this big are kept individually (for Large/Stale views).
    let keepFilesFrom: Int64 = 1 << 20
    /// Folders smaller than this are folded into their parent to save memory.
    let pruneBelow: Int64 = 256 << 10
    /// Depth up to which sub-folders are scanned in parallel.
    let parallelDepth = 4

    private let skip: Set<String>
    private let lock = NSLock()
    private var inodes = Set<InodeKey>()
    private var files: [FileEntry] = []
    private var skippedNodes: [DirNode] = []
    /// mount points of network volumes (smb, nfs, afp, webdav…)
    private let remoteMounts: Set<String>
    /// false when the user scans a cloud folder on purpose
    private let skipCloud: Bool
    /// folders the user always wants left out
    private let alwaysSkip: Set<String>
    private static let cloudFolders = ["/Library/CloudStorage", "/Library/Mobile Documents"]
    /// SF_DATALESS: a File Provider placeholder; listing it downloads from the cloud
    private static let datalessFlag: UInt32 = 0x40000000

    private struct InodeKey: Hashable { let dev: Int32; let ino: UInt64 }

    init(root: String, progress: ScanProgress, alwaysSkip: [String] = []) {
        self.root = root
        self.progress = progress
        // avoid double counting other volumes and the APFS data volume (via firmlinks)
        var s: Set<String> = ["/Volumes", "/System/Volumes", "/dev", "/private/var/vm"]
        s.remove(root)
        skip = s
        remoteMounts = Self.networkMounts()
        skipCloud = !Self.cloudFolders.contains { root.contains($0) }
        // scanning an excluded folder (or something inside it) on purpose overrides the list
        self.alwaysSkip = Set(alwaysSkip.filter { root != $0 && !root.hasPrefix($0 + "/") })
    }

    /// Mount points that are not local disks. MNT_NOWAIT never blocks on a hung server.
    private static func networkMounts() -> Set<String> {
        let n = getfsstat(nil, 0, MNT_NOWAIT)
        guard n > 0 else { return [] }
        var buf = [Darwin.statfs](repeating: Darwin.statfs(), count: Int(n))
        let got = getfsstat(&buf, Int32(MemoryLayout<Darwin.statfs>.stride * buf.count), MNT_NOWAIT)
        var out = Set<String>()
        for var fs in buf.prefix(Int(max(0, got))) where fs.f_flags & UInt32(MNT_LOCAL) == 0 {
            let path = withUnsafePointer(to: &fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            out.insert(path)
        }
        return out
    }

    private func autoSkip(_ path: String, _ st: stat) -> SkipReason? {
        if !alwaysSkip.isEmpty && alwaysSkip.contains(path) { return .always }
        if !remoteMounts.isEmpty && remoteMounts.contains(path) { return .network }
        if skipCloud && (st.st_flags & Self.datalessFlag != 0 || Self.cloudFolders.contains { path.hasSuffix($0) }) {
            return .cloud
        }
        return nil
    }

    private func noteSkipped(_ node: DirNode) {
        lock.lock(); skippedNodes.append(node); lock.unlock()
    }

    func run() -> (DirNode, [FileEntry], [DirNode]) {
        let rootNode = DirNode(path: root, name: (root as NSString).lastPathComponent)
        var st = stat()
        if lstat(root, &st) == 0 {
            rootNode.size = Int64(st.st_blocks) * 512
            rootNode.modified = FS.mtime(st)
        }
        scan(rootNode, depth: 0)
        return (rootNode, files, skippedNodes)
    }

    private func scan(_ node: DirNode, depth: Int) {
        if node.skipped != nil || progress.shouldStop(node.path) { return }
        // the root is always busy for the whole scan; offering to skip it makes no sense
        if depth > 0 { progress.enter(node.path) }
        defer { if depth > 0 { progress.leave(node.path) } }
        guard let dir = opendir(node.path) else { progress.error(); return }

        var subdirs: [DirNode] = []
        var localFiles: [FileEntry] = []
        var total: Int64 = 0, count: Int64 = 0
        var newest: Date = .distantPast

        var seen = 0
        var stoppedEarly = false
        while let ent = readdir(dir) {
            seen += 1
            if seen & 1023 == 0 && progress.shouldStop(node.path) { stoppedEarly = true; break }
            let name = FS.name(of: ent)
            if name == "." || name == ".." { continue }
            let p = FS.join(node.path, name)
            var st = stat()
            if lstat(p, &st) != 0 { progress.error(); continue }
            let sz = Int64(st.st_blocks) * 512
            let mt = FS.mtime(st)

            if FS.isDir(st) {
                if skip.contains(p) { continue }
                let child = DirNode(path: p, name: name)
                child.size = sz
                child.modified = mt
                if let why = autoSkip(p, st) {
                    child.skipped = why
                    noteSkipped(child)
                }
                subdirs.append(child)
                continue
            }

            if st.st_nlink > 1 && FS.isReg(st) {
                let key = InodeKey(dev: st.st_dev, ino: st.st_ino)
                lock.lock()
                let fresh = inodes.insert(key).inserted
                lock.unlock()
                if !fresh { continue }
            }

            total += sz
            count += 1
            // Finder touches .DS_Store just by browsing; it is not a real change.
            if name != ".DS_Store" && mt > newest { newest = mt }
            if FS.isReg(st) && sz >= keepFilesFrom {
                localFiles.append(FileEntry(path: p, size: sz, modified: mt))
            }
        }
        closedir(dir)
        progress.addDir(path: node.path, files: count, bytes: total)

        if depth < parallelDepth && subdirs.count > 1 {
            DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
                scan(subdirs[i], depth: depth + 1)
            }
        } else {
            for c in subdirs { scan(c, depth: depth + 1) }
        }

        for c in subdirs {
            total += c.size
            count += c.fileCount
            if c.modified > newest { newest = c.modified }
        }
        node.size += total
        node.fileCount = count
        // empty folder: keep its own mtime; otherwise use the newest content
        if count > 0 || !subdirs.isEmpty { node.modified = newest }

        node.complete = !stoppedEarly && !progress.shouldStop(node.path) && subdirs.allSatisfy(\.complete)
        if !node.complete && progress.wasSkipped(node.path) {
            node.skipped = .user
            noteSkipped(node)
        }

        // skipped folders stay visible however small, so they can be scanned later;
        // a small folder only keeps children when one of them leads to a skipped folder
        let kept = subdirs.filter { $0.size >= pruneBelow || $0.skipped != nil || !$0.children.isEmpty }
        for c in kept { c.parent = node }
        node.children = kept

        if !localFiles.isEmpty {
            lock.lock()
            files.append(contentsOf: localFiles)
            lock.unlock()
        }
    }
}
