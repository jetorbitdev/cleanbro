import SwiftUI

// MARK: - Scan gate for analysis tools

struct AnalysisGate<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: () -> Content

    private var partialText: String {
        let d = model.progress.dirs, f = model.progress.files
        let dEn = d == 1 ? "1 folder" : "\(Fmt.count(d)) folders"
        let fEn = f == 1 ? "1 file" : "\(Fmt.count(f)) files"
        return L("Scan stopped. Results only include the \(dEn) and \(fEn) read so far. Sizes marked ≥ are incomplete.",
                 "Pemindaian dihentikan. Hasil hanya mencakup \(Fmt.count(d)) folder dan \(Fmt.count(f)) file yang sudah dibaca. Ukuran bertanda ≥ belum lengkap.")
    }

    var body: some View {
        Group {
            switch model.scanState {
            case .idle: idle
            case .scanning: scanning
            case .done:
                VStack(spacing: 0) {
                    if !model.skippedFolders.isEmpty && !model.scanPartial {
                        SkippedBanner(folders: model.skippedFolders)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                        Divider()
                    }
                    if model.scanPartial {
                        PartialBanner(text: partialText) {
                            model.startAnalysis()
                        }
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        Divider()
                    }
                    content()
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Menu {
                    ForEach(AppModel.presets, id: \.path) { p in
                        Button { model.scan(path: p.path) } label: { Label(p.title, systemImage: p.icon) }
                    }
                    Divider()
                    Button(L("Choose Folder…", "Pilih Folder…")) { model.chooseFolder() }
                } label: {
                    Label((model.scanRoot.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                .help(L("Choose the folder to scan", "Pilih folder yang dipindai"))
                .disabled(model.scanState == .scanning)
                Button { model.startAnalysis() } label: { Label(L("Rescan", "Pindai Ulang"), systemImage: "arrow.clockwise") }
                    .help(L("Rescan", "Pindai ulang"))
                    .disabled(model.scanState == .scanning)
            }
        }
    }

    private var idle: some View {
        VStack(spacing: 18) {
            Circle()
                .strokeBorder(Color.accentTeal.opacity(0.15), lineWidth: 10)
                .frame(width: 148, height: 148)
                .overlay(Image(systemName: "internaldrive").font(.system(size: 40)).foregroundStyle(.secondary))
            Text(L("Analyze Disk Usage", "Analisis penggunaan disk"))
                .font(.system(size: 24, weight: .semibold))
            Text(L("CleanBro will measure every folder and file in \((model.scanRoot.path as NSString).abbreviatingWithTildeInPath), then show the largest ones and those that haven't been modified in a long time.",
                   "CleanBro akan menghitung ukuran setiap folder dan file di \((model.scanRoot.path as NSString).abbreviatingWithTildeInPath), lalu menampilkan yang terbesar dan yang sudah lama tidak diubah."))
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 6) {
                ForEach(AppModel.presets, id: \.path) { p in
                    Chip(title: p.title, on: model.scanRoot.path == p.path) { model.scanRoot = URL(fileURLWithPath: p.path) }
                }
            }
            HStack {
                Button(L("Choose Folder…", "Pilih Folder…")) { model.chooseFolder() }.controlSize(.large)
                    .accessibilityIdentifier("analysis.chooseFolder")
                Button(L("Scan", "Pindai")) { model.startAnalysis() }
                    .accessibilityIdentifier("analysis.scan")
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanning: some View {
        let p = model.progress
        return VStack(spacing: 16) {
            Text(Fmt.size(p.bytes))
                .font(.system(size: 48, weight: .light)).monospacedDigit()
            ProgressView().progressViewStyle(.linear).frame(width: 360)
            Text(L("\(p.dirs == 1 ? "1 folder" : "\(Fmt.count(p.dirs)) folders") · \(p.files == 1 ? "1 file" : "\(Fmt.count(p.files)) files")",
                   "\(Fmt.count(p.dirs)) folder · \(Fmt.count(p.files)) file"))
                .foregroundStyle(.secondary).monospacedDigit()
            Text((p.current as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 460)
            StopButton(stopping: model.scanStopping) { model.cancelAnalysis() }
            if !model.scanStopping && !p.stuck.isEmpty {
                SlowFolders(progress: p).padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Kind badge (DIR / ext) that stays legible on selected rows

struct KindBadge: View {
    let item: Item
    /// `.increased` when the row sits on the accent-coloured selection background.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        Text(item.badge)
            .font(.system(size: 9, weight: .bold)).tracking(0.4)
            .foregroundStyle(selected ? Color.white : item.kind.tint)
            .frame(width: 38, height: 24)
            .background(selected ? Color.white.opacity(0.22) : item.kind.tint.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(selected ? Color.white.opacity(0.55) : .clear, lineWidth: 0.5))
    }
}

// MARK: - Table of files/folders with checkboxes and sortable columns

struct ItemTable: View {
    @Environment(AppModel.self) private var model
    let items: [Item]
    @Binding var marked: Set<String>
    @Binding var sortOrder: [KeyPathComparator<Item>]
    var showRelativeDate = false
    var onOpen: ((Item) -> Void)? = nil

    @StateVar private var selection = Set<String>()

    var body: some View {
        let maxSize = max(1, items.map(\.size).max() ?? 1)
        Table(items, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: Binding(
                    get: { marked.contains(item.id) },
                    set: { on in if on { marked.insert(item.id) } else { marked.remove(item.id) } }
                ))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel(item.name)
            }
            .width(20)

            TableColumn(L("Name", "Nama"), value: \.name) { item in
                HStack(spacing: 10) {
                    KindBadge(item: item)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text(item.location).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 220, ideal: 420)

            TableColumn(L("Modified", "Diubah"), value: \.modified) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.date(item.modified))
                    if showRelativeDate {
                        Text(Fmt.relative(item.modified)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(showRelativeDate ? .primary : .secondary)
            }
            .width(min: 100, ideal: 130, max: 180)

            TableColumn(L("Size", "Ukuran"), value: \.size) { item in
                VStack(alignment: .trailing, spacing: 4) {
                    if let why = item.skipped {
                        Text(why.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .help(why.help)
                    } else {
                        Text(item.partial ? "≥ " + Fmt.size(item.size) : Fmt.size(item.size))
                            .monospacedDigit()
                            .foregroundStyle(item.partial ? .secondary : .primary)
                            .help(item.partial ? L("Not all contents of this folder have been counted", "Belum semua isi folder ini terhitung") : "")
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(Color.accentTeal)
                                .frame(width: g.size.width * CGFloat(Double(item.size) / Double(maxSize)))
                        }
                    }
                    .frame(width: 64, height: 3)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 110, max: 140)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let paths = Array(ids)
            if paths.count == 1, let item = items.first(where: { $0.id == paths[0] }), item.isDir {
                if item.skipped != nil {
                    Button(L("Scan This Folder", "Pindai Folder Ini")) { model.scan(path: item.path) }
                } else if let onOpen {
                    Button(L("Open Folder", "Buka Folder")) { onOpen(item) }
                }
                if AppUninstaller.appFolders.contains(where: { item.path.hasPrefix($0 + "/") }) {
                    Button(L("Uninstall…", "Uninstall…")) { model.beginUninstall(path: item.path) }
                }
                if item.kind == .folder {
                    let always = model.alwaysSkip.contains(item.path)
                    Button(always ? L("Stop Skipping This Folder", "Jangan Lewati Lagi") : L("Always Skip When Scanning", "Selalu Lewati Saat Memindai")) {
                        model.setAlwaysSkip(item.path, !always)
                    }
                }
            }
            Button(L("Show in Finder", "Tampilkan di Finder")) { model.reveal(paths) }
            Divider()
            Button(L("Check", "Centang")) { marked.formUnion(paths) }
            Button(L("Uncheck", "Hapus Centang")) { marked.subtract(paths) }
            Divider()
            Button(L("Delete…", "Hapus…"), role: .destructive) {
                model.requestDelete(items.filter { ids.contains($0.id) }, from: model.tool)
            }
        } primaryAction: { ids in
            guard let id = ids.first, let item = items.first(where: { $0.id == id }) else { return }
            if item.skipped != nil { model.scan(path: item.path); return }
            if item.isDir, item.kind != .app, let onOpen { onOpen(item) } else { model.reveal([item.path]) }
        }
        .onKeyPress(.space) {
            guard !selection.isEmpty else { return .ignored }
            if selection.isSubset(of: marked) { marked.subtract(selection) } else { marked.formUnion(selection) }
            return .handled
        }
    }
}

// MARK: - Bottom selection bar

struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let visible: [Item]
    @Binding var marked: Set<String>

    var body: some View {
        let chosen = visible.filter { marked.contains($0.id) }
        let total = chosen.reduce(Int64(0)) { $0 + $1.size }
        HStack(spacing: 10) {
            Text(L("\(chosen.count) selected", "\(chosen.count) dipilih"))
            if !chosen.isEmpty { Text(Fmt.size(total)).foregroundStyle(.secondary).monospacedDigit() }
            Button(chosen.count == visible.count && !visible.isEmpty ? L("Deselect All", "Batal Pilih Semua") : L("Select All", "Pilih Semua")) {
                if chosen.count == visible.count { marked.subtract(visible.map(\.id)) }
                else { marked.formUnion(visible.map(\.id)) }
            }
            .buttonStyle(.link)
            .disabled(visible.isEmpty)
            Spacer()
            Button(L("Show in Finder", "Tampilkan di Finder")) { model.reveal(chosen.map(\.path)) }
                .accessibilityIdentifier("results.reveal")
                .disabled(chosen.isEmpty)
            Button {
                model.requestDelete(chosen, from: model.tool)
            } label: {
                Label(L("Delete…", "Hapus…"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(chosen.isEmpty)
            .keyboardShortcut(.delete, modifiers: .command)
            .accessibilityIdentifier("results.delete")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Filter chips

struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 12).padding(.vertical, 4)
                .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : .primary)
                .background(Capsule().fill(on ? Color.primary : Color.clear))
                .overlay(Capsule().strokeBorder(on ? Color.clear : Color.primary.opacity(0.15)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SortMenu: View {
    @Binding var sortOrder: [KeyPathComparator<Item>]

    var body: some View {
        Menu {
            Button(L("Size — Largest First", "Ukuran — terbesar dulu")) { sortOrder = [KeyPathComparator(\Item.size, order: .reverse)] }
            Button(L("Size — Smallest First", "Ukuran — terkecil dulu")) { sortOrder = [KeyPathComparator(\Item.size, order: .forward)] }
            Divider()
            Button(L("Date — Oldest First", "Tanggal — terlama dulu")) { sortOrder = [KeyPathComparator(\Item.modified, order: .forward)] }
            Button(L("Date — Newest First", "Tanggal — terbaru dulu")) { sortOrder = [KeyPathComparator(\Item.modified, order: .reverse)] }
            Divider()
            Button(L("Name A–Z", "Nama A–Z")) { sortOrder = [KeyPathComparator(\Item.name, order: .forward)] }
        } label: {
            Label(L("Sort", "Urutkan"), systemImage: "arrow.up.arrow.down")
        }
        .help(L("Sort by size or date", "Urutkan berdasarkan ukuran atau tanggal"))
    }
}

struct EmptyRows: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Partial results

struct StopButton: View {
    let stopping: Bool
    let action: () -> Void
    var body: some View {
        if stopping {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Stopping…", "Menghentikan…")).foregroundStyle(.secondary)
            }
        } else {
            Button(L("Stop & Show Results", "Berhenti & Tampilkan Hasil"), action: action)
                .accessibilityIdentifier("scan.stop")
                .keyboardShortcut(.cancelAction)
        }
    }
}

// MARK: - Slow folders while scanning

struct SlowFolders: View {
    @Environment(AppModel.self) private var model
    let progress: ScanProgress.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("These folders are taking a long time", "Folder ini butuh waktu lama"), systemImage: "tortoise")
                .font(.callout.weight(.medium)).foregroundStyle(.orange)
            ForEach(progress.stuck, id: \.path) { dir in
                HStack(spacing: 10) {
                    Text((dir.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(dir.path)
                    Text(L("\(dir.seconds) sec", "\(dir.seconds) dtk")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    let chain = progress.chain(dir)
                    Menu(L("Skip", "Lewati")) {
                        if chain.count > 1 {
                            Section(L("Skip Folder", "Lewati folder")) {
                                ForEach(chain.reversed(), id: \.path) { c in
                                    Button(L("\((c.path as NSString).lastPathComponent)  ·  \(c.seconds) sec", "\((c.path as NSString).lastPathComponent)  ·  \(c.seconds) dtk")) {
                                        model.skipFolder(c.path)
                                    }
                                }
                            }
                        }
                        Section(L("Also in Future Scans", "Juga di pemindaian berikutnya")) {
                            ForEach(chain.reversed(), id: \.path) { c in
                                Button(L("Always Skip \((c.path as NSString).lastPathComponent)", "Selalu lewati \((c.path as NSString).lastPathComponent)")) {
                                    model.skipFolderAlways(c.path)
                                }
                            }
                        }
                    } primaryAction: {
                        model.skipFolder(dir.path)
                    }
                    .fixedSize()
                    .help(L("Click to skip this folder. Open the menu to choose its parent folder or to always skip it.", "Klik untuk melewati folder ini. Buka menu untuk memilih folder induknya atau selalu melewatinya."))
                }
            }
        }
        .padding(12)
        .frame(width: 520)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Settings: folders that are always skipped

struct SkipSettings: View {
    @Environment(AppModel.self) private var model
    @StateVar private var selection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("These folders are always skipped during disk analysis. Cloud folders (Google Drive, iCloud…) and network volumes are skipped automatically.", "Folder ini selalu dilewati saat analisis disk. Folder cloud (Google Drive, iCloud…) dan volume jaringan sudah dilewati otomatis."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(model.alwaysSkip, id: \.self, selection: $selection) { path in
                Label((path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                    .help(path)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if model.alwaysSkip.isEmpty {
                    Text(L("No folders yet", "Belum ada folder")).foregroundStyle(.tertiary)
                }
            }
            .onDeleteCommand { remove() }
            HStack(spacing: 0) {
                Button { model.addAlwaysSkipFolder() } label: { Image(systemName: "plus").frame(width: 22) }
                Button { remove() } label: { Image(systemName: "minus").frame(width: 22) }
                    .disabled(selection.isEmpty)
                Spacer()
            }
            .buttonStyle(.borderless)
        }
        .padding(20)
        .frame(width: 480, height: 340)
    }

    private func remove() {
        for p in selection { model.setAlwaysSkip(p, false) }
        selection = []
    }
}

struct SkippedBanner: View {
    let folders: [DirNode]

    var body: some View {
        let names = folders.prefix(3).map { ($0.path as NSString).abbreviatingWithTildeInPath }
        let n = folders.count
        let list = names.joined(separator: ", ")
        let moreEn = n > 3 ? " and \(n - 3) more" : ""
        let moreId = n > 3 ? " dan \(n - 3) lainnya" : ""
        let text = L("\(n == 1 ? "1 folder" : "\(n) folders") skipped: \(list)\(moreEn). Double-click a skipped folder to scan it. The Always Skip list is in Settings (⌘,).",
                     "\(n) folder dilewati: \(list)\(moreId). Klik dua kali folder yang dilewati untuk memindainya. Daftar Selalu Lewati ada di Pengaturan (⌘,).")
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.forward.circle.fill").foregroundStyle(.secondary)
            Text(text).font(.callout)
                .lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(folders.map(\.path).joined(separator: "\n"))
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PartialBanner: View {
    let text: String
    let rescan: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
            Button(L("Full Scan", "Pindai Lengkap"), action: rescan)
                .accessibilityIdentifier("analysis.fullScan")
                .fixedSize()
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
