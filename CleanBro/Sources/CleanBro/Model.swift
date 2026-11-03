import SwiftUI
import AppKit

// MARK: - Row model shared by all tables

enum FileKind: String, CaseIterable, Identifiable {
    case folder, app, video, archive, disk, image, audio, document, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .folder: "Folder"
        case .app: "Aplikasi"
        case .video: "Video"
        case .archive: "Arsip & Installer"
        case .disk: "Disk Image"
        case .image: "Gambar"
        case .audio: "Audio"
        case .document: "Dokumen"
        case .other: "Lainnya"
        }
    }

    var tint: Color {
        switch self {
        case .folder: .accentTeal
        case .app: .indigo
        case .video: .purple
        case .archive: .orange
        case .disk: .blue
        case .image: .pink
        case .audio: .red
        case .document: .brown
        case .other: .gray
        }
    }

    static func of(path: String, isDir: Bool) -> FileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if isDir { return ext == "app" ? .app : .folder }
        switch ext {
        case "mov", "mp4", "m4v", "mkv", "avi", "wmv", "flv", "webm", "mts", "mpg", "mpeg": return .video
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "xip", "pkg", "mpkg", "zst": return .archive
        case "dmg", "iso", "img", "vmdk", "vdi", "qcow2", "raw", "sparseimage", "hdd", "vhd", "vhdx": return .disk
        case "jpg", "jpeg", "png", "heic", "gif", "tif", "tiff", "psd", "cr2", "cr3", "nef", "arw", "dng", "webp": return .image
        case "mp3", "wav", "aif", "aiff", "flac", "m4a", "aac", "ogg": return .audio
        case "pdf", "doc", "docx", "key", "pages", "numbers", "xls", "xlsx", "ppt", "pptx", "epub": return .document
        default: return .other
        }
    }
}

struct Item: Identifiable, Hashable {
    let path: String
    let name: String
    let location: String
    let size: Int64
    let modified: Date
    let isDir: Bool
    let kind: FileKind
    /// folder whose size is only a lower bound (scan stopped early)
    var partial = false
    var skipped: SkipReason?
    var id: String { path }

    var badge: String {
        if kind == .folder { return "DIR" }
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : String(ext.prefix(4))
    }

    init(path: String, size: Int64, modified: Date, isDir: Bool) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.location = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        self.size = size
        self.modified = modified
        self.isDir = isDir
        self.kind = FileKind.of(path: path, isDir: isDir)
    }

    init(_ n: DirNode) {
        self.init(path: n.path, size: n.size, modified: n.modified, isDir: true)
        partial = !n.complete
        skipped = n.skipped
    }
    init(_ f: FileEntry) { self.init(path: f.path, size: f.size, modified: f.modified, isDir: false) }
}

// MARK: - App state

enum Tool: String, Hashable, CaseIterable {
    case clean, apps, usage, large, stale, dupes
}

struct PendingDelete: Identifiable {
    let id = UUID()
    let tool: Tool
    let items: [(path: String, size: Int64)]
    /// Emptying the Trash: always permanent, no Trash option.
    var emptiesTrash = false
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

@Observable
@MainActor
final class AppModel {
    var tool: Tool = .clean

    // volume
    var volumeName = "Macintosh HD"
    var volumeTotal: Int64 = 0
    var volumeFree: Int64 = 0

    // cleanup
    enum CleanPhase { case idle, scanning, done, finished }
    var cleanPhase: CleanPhase = .idle
    var junk: [JunkCategory] = []
    var junkSelected = Set<String>()
    var freed: Int64 = 0
    var lastDeleteMode: DeleteMode = .trash
    var lastFailures: [(path: String, reason: String)] = []
    /// items already in the Trash that the last move-to-Trash left in place
    var lastKept: [(path: String, size: Int64)] = []

    // trash (nil = not measured yet or unreadable)
    var trashSize: Int64?
    var trashCount: Int?

    // analysis (disk usage / large / stale)
    enum ScanState { case idle, scanning, done }
    var scanRoot = URL(fileURLWithPath: NSHomeDirectory())
    var scanState: ScanState = .idle
    var tree: DirNode?
    var files: [FileEntry] = []
    var scanDuration: TimeInterval = 0
    /// last analysis was stopped by the user; results cover only what was read
    var scanPartial = false
    /// folders left out of the last scan (cloud, network, or skipped by the user)
    var skippedFolders: [DirNode] = []
    /// folders every analysis scan leaves out, kept across launches
    var alwaysSkip: [String] = UserDefaults.standard.stringArray(forKey: "alwaysSkip") ?? [] {
        didSet { UserDefaults.standard.set(alwaysSkip, forKey: "alwaysSkip") }
    }
    var junkPartial = false
    /// cancel was pressed, waiting for workers to wind down
    var scanStopping = false
    var junkStopping = false
    /// live/final counters of the analysis scan and of the junk scan
    var progress = ScanProgress.Snapshot.zero
    var junkProgress = ScanProgress.Snapshot.zero
    /// Bumped on every change of tree/files so views can recompute cached rows.
    var revision = 0

    // duplicates (computed from the analysis file list)
    var dupeState: ScanState = .idle
    var dupes: [DupeGroup] = []
    var dupeProgress = ScanProgress.Snapshot.zero
    var dupeStopping = false
    var dupePartial = false
    /// leave ~/Library, system folders, app bundles and libraries alone
    var dupeSkipProtected = true

    // uninstall
    var apps: [InstalledApp] = []
    var appsLoading = false
    /// app whose uninstall sheet is open
    var uninstallTarget: InstalledApp?

    // selection per tool
    var marks: [Tool: Set<String>] = [:]

    // deletion
    var pendingDelete: PendingDelete?
    var isDeleting = false
    var toast: String?
    /// shows the "grant Full Disk Access" dialog
    var askFullDiskAccess = false

    private var scanJob: ScanProgress?
    private var junkJob: ScanProgress?
    private var dupeJob: ScanProgress?
    private var timer: Timer?
    private var toastTask: Task<Void, Never>?

    init() {
        refreshVolume()
        refreshTrash()
    }

    func marks(for t: Tool) -> Binding<Set<String>> {
        Binding(get: { self.marks[t, default: []] }, set: { self.marks[t] = $0 })
    }

    func flash(_ msg: String) {
        toast = msg
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    /// Opens System Settings › Privacy & Security › Full Disk Access and shows the app
    /// in Finder, so it can be dragged into the list if it isn't there yet.
    func openFullDiskAccessSettings() {
        askFullDiskAccess = false
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        if Bundle.main.bundlePath.hasSuffix(".app") {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }

    func refreshVolume() {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]
        if let v = try? url.resourceValues(forKeys: keys) {
            volumeTotal = Int64(v.volumeTotalCapacity ?? 0)
            volumeFree = v.volumeAvailableCapacityForImportantUsage ?? 0
            volumeName = v.volumeLocalizedName ?? "Macintosh HD"
        }
    }

    func refreshTrash() {
        Task.detached(priority: .utility) {
            let items = DeepCleaner.trashContents()
            await MainActor.run { self.setTrash(items) }
        }
    }

    func requestEmptyTrash() {
        Task.detached(priority: .userInitiated) {
            let items = DeepCleaner.trashContents()
            await MainActor.run {
                self.setTrash(items)
                guard let items else {
                    self.askFullDiskAccess = true
                    return
                }
                guard !items.isEmpty else { self.flash("Sampah sudah kosong"); return }
                self.pendingDelete = PendingDelete(tool: self.tool, items: items, emptiesTrash: true)
            }
        }
    }

    private func setTrash(_ items: [(path: String, size: Int64)]?) {
        trashCount = items?.count
        trashSize = items?.reduce(0) { $0 + $1.size }
    }

    // MARK: progress polling

    /// One timer serves all jobs; it stops itself when neither is running.
    private func ensurePolling() {
        poll()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        if let j = scanJob { progress = j.snapshot }
        if let j = junkJob { junkProgress = j.snapshot }
        if let j = dupeJob { dupeProgress = j.snapshot }
        if scanJob == nil && junkJob == nil && dupeJob == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Stops the analysis scan. Workers wind down quickly and everything
    /// already processed is shown as a partial result.
    func cancelAnalysis() {
        guard let p = scanJob, !scanStopping else { return }
        scanStopping = true
        p.cancel()
    }

    /// Leaves a slow folder out of the running analysis scan.
    func skipFolder(_ path: String) {
        scanJob?.skip(path)
    }

    func setAlwaysSkip(_ path: String, _ on: Bool) {
        if on {
            guard !alwaysSkip.contains(path) else { return }
            alwaysSkip.append(path)
            alwaysSkip.sort()
            flash("\((path as NSString).lastPathComponent) akan selalu dilewati")
        } else {
            alwaysSkip.removeAll { $0 == path }
        }
    }

    /// Leaves `path` out of this scan and every later one.
    func skipFolderAlways(_ path: String) {
        setAlwaysSkip(path, true)
        skipFolder(path)
    }

    func addAlwaysSkipFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.prompt = "Tambahkan"
        panel.message = "Pilih folder yang selalu dilewati saat memindai"
        if panel.runModal() == .OK {
            for url in panel.urls { setAlwaysSkip(url.path, true) }
        }
    }

    /// Stops the junk scan; items already measured are still listed.
    func cancelJunkScan() {
        guard let p = junkJob, !junkStopping else { return }
        junkStopping = true
        p.cancel()
    }

    /// Stops the duplicate search; groups already confirmed are still listed.
    func cancelDupeScan() {
        guard let p = dupeJob, !dupeStopping else { return }
        dupeStopping = true
        p.cancel()
    }

    // MARK: junk

    func startJunkScan() {
        let p = ScanProgress()
        cleanPhase = .scanning
        junkJob = p
        junkStopping = false
        ensurePolling()
        Task.detached(priority: .userInitiated) {
            let cats = JunkScanner.scan(progress: p)
            await MainActor.run {
                guard self.junkJob === p else { return }
                self.junkProgress = p.snapshot
                self.junkJob = nil
                self.junkStopping = false
                self.junkPartial = p.isCancelled
                self.junk = cats
                self.junkSelected = Set(cats.flatMap { $0.items.map(\.path) })
                self.cleanPhase = .done
            }
        }
    }

    var junkSelectedSize: Int64 {
        junk.flatMap(\.items).filter { junkSelected.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    func requestJunkClean() {
        let items = junk.flatMap(\.items).filter { junkSelected.contains($0.path) }
        guard !items.isEmpty else { return }
        pendingDelete = PendingDelete(tool: .clean, items: items.map { ($0.path, $0.size) })
    }

    // MARK: analysis

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // ~/Library and dot-folders are hidden by macOS; show them so they can be picked
        panel.showsHiddenFiles = true
        panel.directoryURL = scanRoot
        panel.prompt = "Pindai"
        panel.message = "Pilih folder atau volume yang ingin dianalisis"
        if panel.runModal() == .OK, let url = panel.url {
            scanRoot = url
            startAnalysis()
        }
    }

    /// Quick picks for folders that are awkward to reach in the open panel.
    static let presets: [(title: String, icon: String, path: String)] = [
        ("Home", "house", NSHomeDirectory()),
        ("Library", "building.columns", NSHomeDirectory() + "/Library"),
        ("Aplikasi", "app.badge", "/Applications"),
        ("Macintosh HD", "internaldrive", "/"),
    ]

    func scan(path: String) {
        scanRoot = URL(fileURLWithPath: path)
        startAnalysis()
    }

    func startAnalysis() {
        resetDupes()
        let p = ScanProgress()
        let root = scanRoot.path
        let excluded = alwaysSkip
        scanState = .scanning
        scanJob = p
        scanStopping = false
        ensurePolling()
        let start = Date()
        let thread = Thread {
            let (tree, files, skipped) = DiskScanner(root: root, progress: p, alwaysSkip: excluded).run()
            let elapsed = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.scanJob === p else { return }
                    self.progress = p.snapshot
                    self.scanJob = nil
                    self.scanStopping = false
                    self.scanPartial = p.isCancelled
                    self.tree = tree
                    self.files = files
                    self.skippedFolders = skipped.sorted { $0.path < $1.path }
                    self.scanDuration = elapsed
                    self.scanState = .done
                    self.marks[.usage] = []; self.marks[.large] = []; self.marks[.stale] = []
                    self.revision += 1
                }
            }
        }
        thread.stackSize = 64 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func node(at path: String) -> DirNode? {
        guard let tree else { return nil }
        if path == tree.path { return tree }
        let prefix = tree.path == "/" ? "/" : tree.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var cur = tree
        for comp in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = cur.children.first(where: { $0.name == comp }) else { return nil }
            cur = next
        }
        return cur
    }

    /// Deepest known node that contains `path` (folders below 256 KB are folded).
    private func deepestAncestor(of path: String) -> DirNode? {
        var p = (path as NSString).deletingLastPathComponent
        while true {
            if let n = node(at: p) { return n }
            let up = (p as NSString).deletingLastPathComponent
            if up == p || up.isEmpty { return nil }
            p = up
        }
    }

    func largeItems(min: Int64, kind: FileKind?, query: String) -> [Item] {
        let q = query.lowercased()
        return files.lazy
            .filter { $0.size >= min }
            .map(Item.init)
            .filter { (kind == nil || $0.kind == kind) && (q.isEmpty || $0.name.lowercased().contains(q)) }
    }

    func staleItems(before cutoff: Date, min: Int64, folders: Bool, files includeFiles: Bool,
                    skipLibrary: Bool, query: String) -> [Item] {
        guard let tree else { return [] }
        let q = query.lowercased()
        let library = NSHomeDirectory() + "/Library"
        // when the scan itself is inside ~/Library, skipping it would hide everything
        let scanningLibrary = tree.path == library || tree.path.hasPrefix(library + "/")
        func skipped(_ p: String) -> Bool {
            skipLibrary && !scanningLibrary && (p == library || p.hasPrefix(library + "/"))
        }

        var out: [Item] = []
        var staleFolders = Set<String>()
        if folders {
            var stack = tree.children
            while let n = stack.popLast() {
                if skipped(n.path) { continue }
                if n.modified < cutoff && n.complete {
                    // whole folder untouched: report it once, don't list its insides
                    if n.size >= min { out.append(Item(n)); staleFolders.insert(n.path) }
                } else {
                    stack.append(contentsOf: n.children)
                }
            }
        }
        if includeFiles {
            let rootPath = tree.path
            for f in self.files where f.modified < cutoff && f.size >= min && !skipped(f.path) {
                if folders {
                    var p = f.parentPath, inside = false
                    while p.count > rootPath.count {
                        if staleFolders.contains(p) { inside = true; break }
                        p = (p as NSString).deletingLastPathComponent
                    }
                    if inside { continue }
                }
                out.append(Item(f))
            }
        }
        if !q.isEmpty { out = out.filter { $0.name.lowercased().contains(q) } }
        return out
    }

    // MARK: duplicates

    func startDupeScan() {
        guard scanState == .done else { return }
        let p = ScanProgress()
        let files = self.files
        let root = tree?.path ?? scanRoot.path
        let skip = dupeSkipProtected
        dupeState = .scanning
        dupeJob = p
        dupeStopping = false
        ensurePolling()
        Task.detached(priority: .userInitiated) {
            let groups = DupeFinder.find(files, root: root, skipProtected: skip, progress: p)
            await MainActor.run {
                guard self.dupeJob === p else { return }
                self.dupeProgress = p.snapshot
                self.dupeJob = nil
                self.dupeStopping = false
                self.dupePartial = p.isCancelled
                self.dupes = groups
                self.marks[.dupes] = []
                self.dupeState = .done
            }
        }
    }

    /// Drops duplicate results; they belong to the file list of the previous scan.
    private func resetDupes() {
        dupeJob?.cancel()
        dupeJob = nil
        dupeStopping = false
        dupePartial = false
        dupes = []
        dupeState = .idle
        marks[.dupes] = []
    }

    var dupeWasted: Int64 { dupes.reduce(0) { $0 + $1.wasted } }

    // MARK: deletion

    func requestDelete(_ items: [Item], from tool: Tool) {
        guard !items.isEmpty else { return }
        pendingDelete = PendingDelete(tool: tool, items: items.map { ($0.path, $0.size) })
    }

    func perform(_ pending: PendingDelete, mode: DeleteMode) {
        pendingDelete = nil
        isDeleting = true
        let targets = pending.items
        Task.detached(priority: .userInitiated) {
            let r = DeepCleaner.delete(targets, mode: mode)
            await MainActor.run { self.finish(r, pending: pending, mode: mode) }
        }
    }

    private func finish(_ r: DeleteResult, pending: PendingDelete, mode: DeleteMode) {
        isDeleting = false
        lastFailures = r.failed
        applyRemoved(r, sizes: pending.items)

        if pending.emptiesTrash {
            var msg = "Sampah dikosongkan · \(Fmt.size(r.freed)) dibebaskan"
            if !r.failed.isEmpty { msg += " · \(r.failed.count) gagal" }
            flash(msg)
        } else if pending.tool == .clean {
            freed = r.freed
            lastDeleteMode = mode
            lastKept = r.kept
            cleanPhase = .finished
        } else {
            let verb = mode == .trash ? "dipindahkan ke Sampah" : "dihapus permanen"
            var msg = "\(Fmt.size(r.freed)) \(verb)"
            if !r.kept.isEmpty { msg += " · \(r.kept.count) sudah di Sampah, dibiarkan" }
            if !r.failed.isEmpty { msg += " · \(r.failed.count) gagal" }
            flash(msg)
        }
    }

    // MARK: uninstall

    func loadApps() {
        guard !appsLoading else { return }
        appsLoading = true
        Task.detached(priority: .userInitiated) {
            let list = AppUninstaller.installedApps()
            await MainActor.run {
                self.apps = list
                self.appsLoading = false
            }
        }
    }

    /// Opens the uninstall sheet for an app or vendor folder found elsewhere (e.g. Disk Usage).
    func beginUninstall(path: String) {
        Task.detached(priority: .userInitiated) {
            let app = AppUninstaller.inspect(path).map { a -> InstalledApp in
                var a = a
                a.size = FS.usage(path).size
                return a
            }
            await MainActor.run {
                if let app { self.uninstallTarget = app } else { self.flash("Bukan aplikasi yang bisa di-uninstall") }
            }
        }
    }

    func uninstallFinished(_ r: DeleteResult, items: [UninstallItem]) {
        applyRemoved(r, sizes: items.map { ($0.path, $0.size) })
        let gone = Set(r.removed)
        apps.removeAll { gone.contains($0.path) }
    }

    /// Drops removed paths from every list and the scanned tree.
    private func applyRemoved(_ r: DeleteResult, sizes items: [(path: String, size: Int64)]) {
        let gone = Set(r.removed)

        // junk
        for i in junk.indices { junk[i].items.removeAll { gone.contains($0.path) } }
        junkSelected.subtract(gone)

        // tree & file list
        if tree != nil {
            let sizes = Dictionary(items.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
            for p in r.removed { applyRemoval(p, size: sizes[p] ?? 0) }
            files.removeAll { f in gone.contains(f.path) || r.removed.contains { f.path.hasPrefix($0 + "/") } }
            revision += 1
        }
        if !dupes.isEmpty {
            for i in dupes.indices {
                dupes[i].items.removeAll { f in gone.contains(f.path) || r.removed.contains { f.path.hasPrefix($0 + "/") } }
            }
            dupes.removeAll { $0.items.count < 2 }
        }
        for t in Tool.allCases { marks[t]?.subtract(gone) }
        refreshVolume()
        refreshTrash()
    }

    private func applyRemoval(_ path: String, size: Int64) {
        var counted: DirNode?
        if let n = node(at: path), n !== tree {
            n.parent?.children.removeAll { $0 === n }
            counted = n.parent
        } else {
            counted = deepestAncestor(of: path)
        }
        while let c = counted {
            c.size = max(0, c.size - size)
            counted = c.parent
        }
    }

    func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

// MARK: - Formatting

enum Fmt {
    static func size(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func count(_ n: Int64) -> String {
        n.formatted(.number.locale(Locale(identifier: "id_ID")))
    }

    private static let dateF: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static let relF: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.unitsStyle = .full
        return f
    }()

    static func date(_ d: Date) -> String { d == .distantPast ? "—" : dateF.string(from: d) }
    static func relative(_ d: Date) -> String { d == .distantPast ? "" : relF.localizedString(for: d, relativeTo: Date()) }
}

extension Color {
    /// oklch(0.55 0.13 175) from the template
    static let accentTeal = Color(red: 0.0, green: 0.53, blue: 0.47)
}
