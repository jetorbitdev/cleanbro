import SwiftUI

private let MB: Int64 = 1 << 20
private let GB: Int64 = 1 << 30

// MARK: - Disk usage (folder breakdown, drill down)

struct DiskUsageView: View {
    @Environment(AppModel.self) private var model
    @StateVar private var currentPath: String?
    @StateVar private var sortOrder = [KeyPathComparator(\Item.size, order: .reverse)]
    @StateVar private var rows: [Item] = []

    private var current: DirNode? {
        if let p = currentPath, let n = model.node(at: p) { return n }
        return model.tree
    }

    var body: some View {
        let node = current
        VStack(spacing: 0) {
            if let node {
                header(node)
                Divider()
            }
            if rows.isEmpty {
                EmptyRows(text: L("This folder is empty or everything in it is small.", "Folder ini kosong atau isinya kecil semua."))
            } else {
                ItemTable(items: rows, marked: model.marks(for: .usage), sortOrder: $sortOrder) { item in
                    currentPath = item.path
                }
            }
            SelectionBar(visible: rows, marked: model.marks(for: .usage))
        }
        .navigationTitle(L("Disk Usage", "Penggunaan Disk"))
        .navigationSubtitle(node.map {
            L("\(Fmt.size($0.size)) · \(Fmt.count($0.fileCount)) \($0.fileCount == 1 ? "file" : "files")",
              "\(Fmt.size($0.size)) · \(Fmt.count($0.fileCount)) file")
        } ?? "")
        .toolbar {
            ToolbarItem { SortMenu(sortOrder: $sortOrder) }
        }
        .task(id: Key(path: node?.path, rev: model.revision, sort: sortOrder)) { recompute() }
        .onChange(of: model.tree?.path) { currentPath = nil }
    }

    private struct Key: Hashable { let path: String?; let rev: Int; let sort: [KeyPathComparator<Item>] }

    private func recompute() {
        guard let node = current else { rows = []; return }
        var items = node.children.map(Item.init)
        items += model.files.filter { $0.parentPath == node.path }.map(Item.init)
        rows = items.sorted(using: sortOrder)
    }

    private func header(_ node: DirNode) -> some View {
        var chain: [DirNode] = []
        var n: DirNode? = node
        while let c = n { chain.insert(c, at: 0); n = c.parent }
        let parentSize = node.parent?.size ?? node.size
        let frac = parentSize > 0 ? Double(node.size) / Double(parentSize) : 1

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Button { if let p = node.parent { currentPath = p.path } } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(node.parent == nil)
                .keyboardShortcut("[", modifiers: .command)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(chain) { c in
                            if c !== chain.first { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                            Button(c === chain.first ? (c.path as NSString).abbreviatingWithTildeInPath : c.name) {
                                currentPath = c.path
                            }
                            .buttonStyle(.plain)
                            .fontWeight(c === node ? .semibold : .regular)
                            .foregroundStyle(c === node ? .primary : .secondary)
                        }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text((node.complete ? "" : "≥ ") + Fmt.size(node.size)).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                if node.parent != nil {
                    Text(String(format: L("%.1f%% of parent folder", "%.1f%% dari folder induk"), frac * 100)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(L("Last modified \(Fmt.relative(node.modified))", "Terakhir berubah \(Fmt.relative(node.modified))")).font(.caption).foregroundStyle(.secondary)
            }
            if model.progress.errors > 0 && node.parent == nil {
                HStack(spacing: 8) {
                    Label(L(model.progress.errors == 1
                              ? "1 item couldn't be read. Grant CleanBro Full Disk Access in System Settings › Privacy & Security."
                              : "\(Fmt.count(model.progress.errors)) items couldn't be read. Grant CleanBro Full Disk Access in System Settings › Privacy & Security.",
                              "\(Fmt.count(model.progress.errors)) item tidak bisa dibaca. Beri CleanBro izin Full Disk Access di Pengaturan Sistem › Privasi & Keamanan."),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Button(L("Grant Access…", "Beri Akses…")) { model.askFullDiskAccess = true }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

// MARK: - Large files

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @StateVar private var minSize: Int64 = 100 * MB
    @StateVar private var kind: FileKind?
    @StateVar private var query = ""
    @StateVar private var sortOrder = [KeyPathComparator(\Item.size, order: .reverse)]
    @StateVar private var rows: [Item] = []

    private let kinds: [FileKind?] = [nil, .video, .archive, .disk, .image, .audio, .document, .other]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(kinds, id: \.self) { k in
                        Chip(title: k?.label ?? L("All", "Semua"), on: kind == k) { kind = k }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            }
            Divider()
            if rows.isEmpty {
                EmptyRows(text: L("No files match this filter.", "Tidak ada file yang cocok dengan filter ini."))
            } else {
                ItemTable(items: rows, marked: model.marks(for: .large), sortOrder: $sortOrder)
            }
            SelectionBar(visible: rows, marked: model.marks(for: .large))
        }
        .navigationTitle(L("Large Files", "File Besar"))
        .navigationSubtitle(L("\(rows.count) \(rows.count == 1 ? "file" : "files") · \(Fmt.size(rows.reduce(0) { $0 + $1.size }))",
                              "\(rows.count) file · \(Fmt.size(rows.reduce(0) { $0 + $1.size }))"))
        .searchable(text: $query, placement: .toolbar, prompt: L("Search file names", "Cari nama file"))
        .toolbar {
            ToolbarItem {
                Picker(L("Minimum", "Minimal"), selection: $minSize) {
                    Text("50 MB").tag(50 * MB)
                    Text("100 MB").tag(100 * MB)
                    Text("500 MB").tag(500 * MB)
                    Text("1 GB").tag(GB)
                }
                .pickerStyle(.segmented)
                .help(L("Minimum size", "Ukuran minimal"))
            }
            ToolbarItem { SortMenu(sortOrder: $sortOrder) }
        }
        .task(id: Key(min: minSize, kind: kind, q: query, rev: model.revision, sort: sortOrder)) {
            rows = model.largeItems(min: minSize, kind: kind, query: query).sorted(using: sortOrder)
        }
    }

    private struct Key: Hashable { let min: Int64; let kind: FileKind?; let q: String; let rev: Int; let sort: [KeyPathComparator<Item>] }
}

// MARK: - Stale (not modified for a long time)

struct StaleView: View {
    @Environment(AppModel.self) private var model

    enum Age: Int, CaseIterable, Identifiable {
        case m6 = 6, y1 = 12, y2 = 24, y3 = 36, y5 = 60
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .m6: L("> 6 months", "> 6 bulan")
            case .y1: L("> 1 year", "> 1 tahun")
            case .y2: L("> 2 years", "> 2 tahun")
            case .y3: L("> 3 years", "> 3 tahun")
            case .y5: L("> 5 years", "> 5 tahun")
            }
        }
        var cutoff: Date { Calendar.current.date(byAdding: .month, value: -rawValue, to: Date()) ?? Date() }
    }

    enum Show: CaseIterable {
        case all, files, folders
        var label: String {
            switch self {
            case .all: L("All", "Semua")
            case .files: L("Files", "File")
            case .folders: L("Folders", "Folder")
            }
        }
    }

    @StateVar private var age: Age = .y1
    @StateVar private var show: Show = .all
    @StateVar private var minSize: Int64 = 10 * MB
    @StateVar private var skipLibrary = true
    @StateVar private var query = ""
    @StateVar private var sortOrder = [KeyPathComparator(\Item.modified, order: .forward)]
    @StateVar private var rows: [Item] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text(L("Not modified", "Tidak diubah")).font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(Age.allCases) { a in
                            Chip(title: a.label, on: age == a) { age = a }
                        }
                    }
                    .padding(.leading, 20)
                }
                Toggle(L("Skip ~/Library", "Lewati ~/Library"), isOn: $skipLibrary)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .fixedSize()
                    .help(L("The Library folder holds app data that rarely changes but is still in use", "Folder Library berisi data aplikasi yang jarang berubah tapi masih dipakai"))
                    .padding(.trailing, 20)
            }
            .padding(.vertical, 10)
            Divider()
            if rows.isEmpty {
                EmptyRows(text: L("No long-unmodified files or folders match this filter.", "Tidak ada file atau folder yang lama tak berubah dengan filter ini."))
            } else {
                ItemTable(items: rows, marked: model.marks(for: .stale), sortOrder: $sortOrder,
                          showRelativeDate: true)
            }
            SelectionBar(visible: rows, marked: model.marks(for: .stale))
        }
        .navigationTitle(L("Not Modified Lately", "Lama Tak Diubah"))
        .navigationSubtitle(L("\(rows.count) \(rows.count == 1 ? "item" : "items") · \(Fmt.size(rows.reduce(0) { $0 + $1.size }))",
                              "\(rows.count) item · \(Fmt.size(rows.reduce(0) { $0 + $1.size }))"))
        .searchable(text: $query, placement: .toolbar, prompt: L("Search names", "Cari nama"))
        .toolbar {
            ToolbarItem {
                Picker(L("Show", "Tampilkan"), selection: $show) {
                    ForEach(Show.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Picker(L("Minimum", "Minimal"), selection: $minSize) {
                    Text("≥ 1 MB").tag(MB)
                    Text("≥ 10 MB").tag(10 * MB)
                    Text("≥ 100 MB").tag(100 * MB)
                    Text("≥ 1 GB").tag(GB)
                }
                .help(L("Minimum size", "Ukuran minimal"))
            }
            ToolbarItem { SortMenu(sortOrder: $sortOrder) }
        }
        .task(id: Key(age: age, show: show, min: minSize, lib: skipLibrary, q: query, rev: model.revision, sort: sortOrder)) {
            rows = model.staleItems(before: age.cutoff, min: minSize,
                                    folders: show != .files, files: show != .folders,
                                    skipLibrary: skipLibrary, query: query)
                .sorted(using: sortOrder)
        }
    }

    private struct Key: Hashable {
        let age: Age; let show: Show; let min: Int64; let lib: Bool; let q: String; let rev: Int
        let sort: [KeyPathComparator<Item>]
    }
}
