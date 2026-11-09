import SwiftUI
import AppKit

struct HomebrewView: View {
    @Environment(AppModel.self) private var model
    @StateVar private var query = ""
    @StateVar private var filter = Filter.all
    @StateVar private var selection = Set<BrewPackage.ID>()
    @StateVar private var sortOrder = [KeyPathComparator(\BrewPackage.size, order: .reverse)]
    @StateVar private var confirm: [BrewPackage]?

    enum Filter: Hashable, CaseIterable {
        case all, formulae, casks, outdated, unused

        var title: String {
            switch self {
            case .all: L("All", "Semua")
            case .formulae: "Formulae"
            case .casks: "Casks"
            case .outdated: L("Outdated", "Usang")
            case .unused: L("Unused Dependencies", "Dependensi Tak Terpakai")
            }
        }

        func includes(_ p: BrewPackage) -> Bool {
            switch self {
            case .all: true
            case .formulae: p.kind == .formula
            case .casks: p.kind == .cask
            case .outdated: p.outdated
            case .unused: p.isUnusedDependency
            }
        }
    }

    var body: some View {
        Group {
            if Homebrew.executable == nil {
                notInstalled
            } else {
                content
            }
        }
        .navigationTitle("Homebrew")
        .task { if !model.brewLoaded { model.loadBrew() } }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { pkgs in
            Button(L("Uninstall", "Uninstall"), role: .destructive) {
                model.brewUninstall(pkgs, zap: false)
                selection = []
            }
            if pkgs.contains(where: { $0.kind == .cask }) {
                Button(L("Uninstall and Remove App Data (Zap)", "Uninstall dan Hapus Data Aplikasi (Zap)"), role: .destructive) {
                    model.brewUninstall(pkgs, zap: true)
                    selection = []
                }
            }
            Button(L("Cancel", "Batal"), role: .cancel) {}
        } message: { pkgs in
            Text(L("Runs `brew uninstall` for \(pkgs.map(\.name).joined(separator: ", ")). This can't be undone; reinstall with `brew install` if needed. Zap also deletes the preferences, caches and support files the cask lists.",
                   "Menjalankan `brew uninstall` untuk \(pkgs.map(\.name).joined(separator: ", ")). Tidak bisa dibatalkan; pasang lagi dengan `brew install` bila perlu. Zap juga menghapus preferensi, cache, dan file pendukung yang didaftarkan cask."))
        }
    }

    private var confirmTitle: String {
        guard let pkgs = confirm else { return "" }
        let size = Fmt.size(pkgs.reduce(0) { $0 + $1.size })
        return pkgs.count == 1
            ? L("Uninstall \(pkgs[0].name) (\(size))?", "Uninstall \(pkgs[0].name) (\(size))?")
            : L("Uninstall \(pkgs.count) packages (\(size))?", "Uninstall \(pkgs.count) paket (\(size))?")
    }

    // MARK: list

    private var content: some View {
        let q = query.lowercased()
        let rows = model.brewPackages
            .filter { filter.includes($0) }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.title.lowercased().contains(q) || $0.desc.lowercased().contains(q) }
            .sorted(using: sortOrder)
        let chosen = model.brewPackages.filter { selection.contains($0.id) }
        return VStack(spacing: 0) {
            if model.brewLoading && model.brewPackages.isEmpty {
                ProgressView(L("Reading Homebrew packages…", "Membaca paket Homebrew…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                EmptyRows(text: L("No matching packages.", "Tidak ada paket yang cocok."))
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn(L("Name", "Nama"), value: \.name) { p in nameCell(p) }
                        .width(min: 240, ideal: 420)
                    TableColumn(L("Type", "Jenis"), value: \.kindLabel) { p in
                        Text(p.kindLabel).foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 70, max: 90)
                    TableColumn(L("Version", "Versi"), value: \.version) { p in versionCell(p) }
                        .width(min: 90, ideal: 150, max: 240)
                    TableColumn(L("Size", "Ukuran"), value: \.size) { p in
                        Text(Fmt.size(p.size)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 80, ideal: 100, max: 130)
                }
                .contextMenu(forSelectionType: BrewPackage.ID.self) { ids in
                    let pkgs = model.brewPackages.filter { ids.contains($0.id) }
                    if !pkgs.isEmpty {
                        Button(L("Uninstall…", "Uninstall…")) { confirm = pkgs }
                            .disabled(blocker(pkgs) != nil)
                        Button(L("Show in Finder", "Tampilkan di Finder")) { model.reveal(pkgs.compactMap(\.paths.first)) }
                        if pkgs.count == 1, let url = URL(string: pkgs[0].homepage), !pkgs[0].homepage.isEmpty {
                            Button(L("Open Homepage", "Buka Homepage")) { NSWorkspace.shared.open(url) }
                        }
                        Button(L("Copy Name", "Salin Nama")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pkgs.map(\.name).joined(separator: " "), forType: .string)
                        }
                    }
                }
            }
            Divider()
            footer(rows: rows, chosen: chosen)
        }
        .searchable(text: $query, placement: .toolbar, prompt: L("Search packages", "Cari paket"))
        .toolbar {
            ToolbarItem {
                Picker(L("Show", "Tampilkan"), selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { f in
                        Text("\(f.title) (\(model.brewPackages.filter(f.includes).count))").tag(f)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            ToolbarItem {
                Button { model.brewCleanup() } label: {
                    Label(L("Clean Up", "Bersihkan"), systemImage: "sparkles")
                }
                .help(L("Run `brew cleanup`: removes old versions and the download cache",
                        "Jalankan `brew cleanup`: menghapus versi lama dan cache unduhan"))
                .disabled(model.brewBusy != nil || model.brewLoading)
            }
            ToolbarItem {
                Button { model.loadBrew() } label: { Label(L("Reload", "Muat Ulang"), systemImage: "arrow.clockwise") }
                    .disabled(model.brewLoading)
            }
        }
    }

    private func nameCell(_ p: BrewPackage) -> some View {
        HStack(spacing: 10) {
            Group {
                if let app = p.appPath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable()
                } else {
                    Image(systemName: p.kind == .cask ? "shippingbox" : "terminal")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(p.title).lineLimit(1)
                    if p.title != p.name {
                        Text(p.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if p.isUnusedDependency {
                        Tag(text: L("unused", "tak terpakai"), color: .orange)
                    } else if p.kind == .formula && !p.onRequest {
                        Tag(text: L("dependency", "dependensi"), color: .secondary)
                    }
                    if p.pinned { Tag(text: "pinned", color: .accentTeal) }
                }
                Text(p.desc.isEmpty ? " " : p.desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .help(p.usedBy.isEmpty ? p.desc : L("\(p.desc)\nNeeded by: \(p.usedBy.joined(separator: ", "))",
                                            "\(p.desc)\nDibutuhkan oleh: \(p.usedBy.joined(separator: ", "))"))
    }

    @ViewBuilder
    private func versionCell(_ p: BrewPackage) -> some View {
        if p.outdated && !p.latest.isEmpty && p.latest != p.version {
            HStack(spacing: 4) {
                Text(p.version)
                Image(systemName: "arrow.right").font(.caption2)
                Text(p.latest).foregroundStyle(.orange)
            }
            .monospacedDigit().lineLimit(1)
            .help(L("Update available: brew upgrade \(p.name)", "Ada pembaruan: brew upgrade \(p.name)"))
        } else {
            Text(p.version).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: footer

    private func footer(rows: [BrewPackage], chosen: [BrewPackage]) -> some View {
        let old = model.brewPackages.reduce(0) { $0 + $1.oldVersionsSize }
        let block = blocker(chosen)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("\(rows.count) \(rows.count == 1 ? "package" : "packages") · \(Fmt.size(rows.reduce(0) { $0 + $1.size }))",
                       "\(rows.count) paket · \(Fmt.size(rows.reduce(0) { $0 + $1.size }))"))
                    .foregroundStyle(.secondary).monospacedDigit()
                if let block {
                    Text(block).font(.caption).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail)
                } else if old > 0 {
                    Text(L("Old versions take \(Fmt.size(old)); Clean Up removes them.",
                           "Versi lama memakan \(Fmt.size(old)); Bersihkan akan menghapusnya."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                confirm = chosen
            } label: {
                Label(L("Uninstall…", "Uninstall…"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .disabled(chosen.isEmpty || block != nil || model.brewBusy != nil)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    /// Why the packages can't be uninstalled: another installed package still needs them.
    private func blocker(_ pkgs: [BrewPackage]) -> String? {
        let leaving = Set(pkgs.map(\.name))
        for p in pkgs {
            let needed = p.usedBy.filter { !leaving.contains($0) }
            if !needed.isEmpty {
                return L("\(p.name) is needed by \(needed.joined(separator: ", "))",
                         "\(p.name) dibutuhkan oleh \(needed.joined(separator: ", "))")
            }
        }
        return nil
    }

    // MARK: not installed

    private var notInstalled: some View {
        VStack(spacing: 12) {
            Image(systemName: "mug").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(L("Homebrew Isn't Installed", "Homebrew belum terpasang")).font(.title3.weight(.semibold))
            Text(L("CleanBro looks for brew in /opt/homebrew and /usr/local.",
                   "CleanBro mencari brew di /opt/homebrew dan /usr/local."))
                .foregroundStyle(.secondary)
            Button(L("Open brew.sh", "Buka brew.sh")) { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
                .accessibilityIdentifier("brew.openSite")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct BrewBusyOverlay: View {
    let text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(text).font(.headline).multilineTextAlignment(.center).lineLimit(3)
            }
            .padding(28)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
