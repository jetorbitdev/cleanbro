import SwiftUI
import AppKit

// MARK: - App list

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @StateVar private var query = ""
    @StateVar private var selection: InstalledApp.ID?
    @StateVar private var sortOrder = [KeyPathComparator(\InstalledApp.size, order: .reverse)]

    var body: some View {
        let q = query.lowercased()
        let rows = model.apps
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .sorted(using: sortOrder)
        VStack(spacing: 0) {
            if model.appsLoading && model.apps.isEmpty {
                ProgressView(L("Reading apps…", "Membaca aplikasi…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                EmptyRows(text: L("No matching apps.", "Tidak ada aplikasi yang cocok."))
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn(L("Name", "Nama"), value: \.name) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(app.name).lineLimit(1)
                                    if let cask = model.brewCask(for: app.path) {
                                        Tag(text: "Homebrew", color: .accentTeal)
                                            .help(L("Installed with Homebrew (brew install --cask \(cask.name))",
                                                    "Dipasang lewat Homebrew (brew install --cask \(cask.name))"))
                                    }
                                }
                                Text(app.location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .width(min: 240, ideal: 420)
                    TableColumn(L("Size", "Ukuran"), value: \.size) { app in
                        Text(Fmt.size(app.size)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 90, ideal: 110, max: 140)
                }
                .contextMenu(forSelectionType: InstalledApp.ID.self) { ids in
                    if let id = ids.first, let app = model.apps.first(where: { $0.id == id }) {
                        Button(L("Uninstall…", "Uninstall…")) { model.uninstallTarget = app }
                        Button(L("Show in Finder", "Tampilkan di Finder")) { model.reveal([app.path]) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let app = model.apps.first(where: { $0.id == id }) { model.uninstallTarget = app }
                }
            }
            Divider()
            HStack {
                Text(L("\(rows.count) \(rows.count == 1 ? "app" : "apps") · \(Fmt.size(rows.reduce(0) { $0 + $1.size }))",
                         "\(rows.count) aplikasi · \(Fmt.size(rows.reduce(0) { $0 + $1.size }))"))
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button {
                    if let app = model.apps.first(where: { $0.id == selection }) { model.uninstallTarget = app }
                } label: {
                    Label(L("Uninstall…", "Uninstall…"), systemImage: "trash")
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(selection == nil)
                .keyboardShortcut(.delete, modifiers: .command)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
        }
        .navigationTitle(L("Uninstall Apps", "Uninstall Aplikasi"))
        .searchable(text: $query, placement: .toolbar, prompt: L("Search apps", "Cari aplikasi"))
        .toolbar {
            ToolbarItem {
                Button { model.loadApps() } label: { Label(L("Reload", "Muat Ulang"), systemImage: "arrow.clockwise") }
                    .disabled(model.appsLoading)
            }
        }
        .task {
            if model.apps.isEmpty { model.loadApps() }
            // to mark apps that came from a Homebrew cask
            if !model.brewLoaded { model.loadBrew() }
        }
    }
}

// MARK: - Uninstall sheet

struct UninstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: InstalledApp

    private enum Phase { case loading, review, working, done(DeleteResult) }
    @StateVar private var phase = Phase.loading
    @StateVar private var items: [UninstallItem] = []
    @StateVar private var chosen = Set<String>()
    @StateVar private var running: [NSRunningApplication] = []
    @StateVar private var official: String?
    @StateVar private var permanent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            switch phase {
            case .loading:
                ProgressView(L("Finding files that belong to \(app.name)…", "Mencari file milik \(app.name)…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .review:
                review
            case .working:
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L("Removing \(app.name)…", "Menghapus \(app.name)…"))
                    Text(L("Enter your admin password if prompted.", "Masukkan password admin jika diminta.")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done(let r):
                result(r)
            }
        }
        .frame(width: 640, height: 560)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Uninstall \(app.name)", "Uninstall \(app.name)")).font(.title2.weight(.semibold))
                Text((app.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // MARK: review

    private var review: some View {
        let selected = items.filter { chosen.contains($0.id) }
        let adminCount = selected.filter(\.needsAdmin).count
        let runningNames = running.compactMap(\.localizedName).joined(separator: ", ")
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                if let cask {
                    Notice(icon: "mug", tint: .accentTeal,
                           text: L("\(app.name) was installed with Homebrew (cask \(cask.name)). Uninstall it with Homebrew so brew stops tracking it; removing it here leaves brew thinking it's still installed.",
                                   "\(app.name) dipasang lewat Homebrew (cask \(cask.name)). Uninstall lewat Homebrew agar brew berhenti mencatatnya; kalau dihapus di sini, brew masih menganggapnya terpasang.")) {
                        Menu(L("Use Homebrew", "Pakai Homebrew")) {
                            Button(L("Uninstall", "Uninstall")) { brewUninstall(zap: false) }
                            Button(L("Uninstall and Remove App Data (Zap)", "Uninstall dan Hapus Data Aplikasi (Zap)")) { brewUninstall(zap: true) }
                        }
                        .fixedSize()
                    }
                }
                if let official {
                    Notice(icon: "wrench.and.screwdriver", tint: .accentTeal,
                           text: L("\(app.name) has an official uninstaller. Run it first so its background services are shut down properly, then clean up whatever is left here.",
                                   "\(app.name) punya uninstaller resmi. Sebaiknya jalankan itu dulu agar layanan latar belakangnya ikut dimatikan dengan benar, lalu bersihkan sisanya di sini.")) {
                        Button(L("Open Uninstaller", "Buka Uninstaller")) { NSWorkspace.shared.open(URL(fileURLWithPath: official)) }
                    }
                }
                if !running.isEmpty {
                    Notice(icon: "exclamationmark.triangle.fill", tint: .orange,
                           text: L(running.count == 1
                                ? "\(runningNames) is running and will be asked to quit. If it stays open (for example, waiting for you to save your work), the uninstall is cancelled."
                                : "\(runningNames) are running and will be asked to quit. If any stay open (for example, waiting for you to save your work), the uninstall is cancelled.",
                                "\(runningNames) sedang berjalan dan akan diminta keluar. Jika masih terbuka (misalnya menunggu Anda menyimpan pekerjaan), uninstall dibatalkan."))
                }
            }
            .padding(.horizontal, 20).padding(.top, official != nil || cask != nil || !running.isEmpty ? 12 : 0)

            List {
                section(L("App", "Aplikasi"), items.filter { $0.match == .app })
                section(L("Leftover Files", "Sisa file"), items.filter { $0.match == .sure })
                section(L("Possibly Related", "Mungkin terkait"), items.filter { $0.match == .maybe },
                        note: L("Similar name or same vendor. Another app from this vendor may use these, so they are not selected automatically.",
                                "Nama mirip atau dari vendor yang sama. Bisa jadi dipakai aplikasi lain dari vendor ini, jadi tidak dicentang otomatis."))
            }
            .listStyle(.inset)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if adminCount > 0 {
                    Label(L(adminCount == 1
                              ? "1 system-owned item needs an admin password and is deleted permanently."
                              : "\(adminCount) system-owned items need an admin password and are deleted permanently.",
                              "\(adminCount) item milik sistem: butuh password admin dan langsung dihapus permanen."),
                          systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Toggle(L("Delete permanently (skip Trash)", "Hapus permanen (tidak lewat Sampah)"), isOn: $permanent).toggleStyle(.checkbox)
                        .accessibilityIdentifier("uninstall.permanent")
                    Spacer()
                    Text(L("\(selected.count) \(selected.count == 1 ? "item" : "items") · \(Fmt.size(selected.reduce(0) { $0 + $1.size }))",
                           "\(selected.count) item · \(Fmt.size(selected.reduce(0) { $0 + $1.size }))"))
                        .foregroundStyle(.secondary).monospacedDigit()
                    Button(L("Cancel", "Batal")) { dismiss() }.keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("uninstall.cancel")
                    Button(L("Uninstall", "Uninstall")) { start(selected) }
                        .accessibilityIdentifier("uninstall.confirm")
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(selected.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [UninstallItem], note: String? = nil) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row($0) }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    let all = rows.allSatisfy { chosen.contains($0.id) }
                    Button(all ? L("Deselect All", "Batal Pilih") : L("Select All", "Pilih Semua")) {
                        if all { chosen.subtract(rows.map(\.id)) } else { chosen.formUnion(rows.map(\.id)) }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            } footer: {
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func row(_ it: UninstallItem) -> some View {
        Toggle(isOn: Binding(
            get: { chosen.contains(it.id) },
            set: { if $0 { chosen.insert(it.id) } else { chosen.remove(it.id) } }
        )) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text((it.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text("\(it.kind) · \(((it.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                .help(it.path)
                Spacer()
                if it.needsAdmin {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        .help(L("System-owned, needs an admin password", "Milik sistem, butuh password admin"))
                }
                Text(Fmt.size(it.size)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .contextMenu { Button(L("Show in Finder", "Tampilkan di Finder")) { model.reveal([it.path]) } }
    }

    // MARK: result

    private func result(_ r: DeleteResult) -> some View {
        VStack(spacing: 14) {
            Image(systemName: r.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(r.failed.isEmpty ? Color.accentTeal : .orange)
            Text(r.failed.isEmpty ? L("\(app.name) has been removed", "\(app.name) sudah dihapus")
                                   : L("Some items couldn't be removed", "Sebagian tidak bisa dihapus"))
                .font(.title3.weight(.semibold))
            Text(L("\(r.removed.count) \(r.removed.count == 1 ? "item" : "items") · \(Fmt.size(r.freed)) freed",
                   "\(r.removed.count) item · \(Fmt.size(r.freed)) dibebaskan"))
                .foregroundStyle(.secondary)
            if !r.failed.isEmpty {
                List(r.failed, id: \.path) { f in
                    VStack(alignment: .leading, spacing: 1) {
                        Text((f.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Text(f.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.bordered).frame(maxHeight: 200)
            }
            Button(L("Close", "Tutup")) { dismiss() }.keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("uninstall.close")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: actions

    private var cask: BrewPackage? { model.brewCask(for: app.path) }

    private func brewUninstall(zap: Bool) {
        guard let cask else { return }
        dismiss()
        model.brewUninstall([cask], zap: zap)
    }

    private func load() async {
        let app = app
        let (found, uninstaller) = await Task.detached(priority: .userInitiated) {
            (AppUninstaller.items(for: app), AppUninstaller.officialUninstaller(for: app))
        }.value
        items = found
        official = uninstaller
        running = AppUninstaller.running(app)
        chosen = Set(found.filter { $0.match != .maybe }.map(\.id))
        phase = .review
    }

    private func start(_ selected: [UninstallItem]) {
        phase = .working
        let toQuit = selected.contains { $0.match == .app } ? running : []
        let mode: DeleteMode = permanent ? .permanent : .trash
        Task.detached(priority: .userInitiated) {
            let still = toQuit.isEmpty ? [] : AppUninstaller.quit(toQuit)
            let r: DeleteResult
            if still.isEmpty {
                r = AppUninstaller.remove(selected, mode: mode)
            } else {
                // removing files under a running app can corrupt its data; touch nothing
                let names = still.compactMap(\.localizedName).joined(separator: ", ")
                let reason = L(still.count == 1
                                ? "\(names) is still running. Save your work and quit the app, then try again."
                                : "\(names) are still running. Save your work and quit the apps, then try again.",
                                "\(names) masih berjalan. Simpan pekerjaan dan tutup aplikasinya, lalu coba lagi.")
                r = DeleteResult(failed: selected.map { ($0.path, reason) })
            }
            await MainActor.run {
                model.uninstallFinished(r, items: selected)
                phase = .done(r)
            }
        }
    }
}

private struct Notice<Action: View>: View {
    let icon: String
    let tint: Color
    let text: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension Notice where Action == EmptyView {
    init(icon: String, tint: Color, text: String) {
        self.init(icon: icon, tint: tint, text: text) { EmptyView() }
    }
}
