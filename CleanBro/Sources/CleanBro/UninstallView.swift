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
                ProgressView("Membaca aplikasi…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                EmptyRows(text: "Tidak ada aplikasi yang cocok.")
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Nama", value: \.name) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                Text(app.location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .width(min: 240, ideal: 420)
                    TableColumn("Ukuran", value: \.size) { app in
                        Text(Fmt.size(app.size)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 90, ideal: 110, max: 140)
                }
                .contextMenu(forSelectionType: InstalledApp.ID.self) { ids in
                    if let id = ids.first, let app = model.apps.first(where: { $0.id == id }) {
                        Button("Uninstall…") { model.uninstallTarget = app }
                        Button("Tampilkan di Finder") { model.reveal([app.path]) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let app = model.apps.first(where: { $0.id == id }) { model.uninstallTarget = app }
                }
            }
            Divider()
            HStack {
                Text("\(rows.count) aplikasi · \(Fmt.size(rows.reduce(0) { $0 + $1.size }))")
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button {
                    if let app = model.apps.first(where: { $0.id == selection }) { model.uninstallTarget = app }
                } label: {
                    Label("Uninstall…", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(selection == nil)
                .keyboardShortcut(.delete, modifiers: .command)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
        }
        .navigationTitle("Uninstall Aplikasi")
        .searchable(text: $query, placement: .toolbar, prompt: "Cari aplikasi")
        .toolbar {
            ToolbarItem {
                Button { model.loadApps() } label: { Label("Muat Ulang", systemImage: "arrow.clockwise") }
                    .disabled(model.appsLoading)
            }
        }
        .task { if model.apps.isEmpty { model.loadApps() } }
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
                ProgressView("Mencari file milik \(app.name)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .review:
                review
            case .working:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Menghapus \(app.name)…")
                    Text("Masukkan password admin jika diminta.").font(.caption).foregroundStyle(.secondary)
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
                Text("Uninstall \(app.name)").font(.title2.weight(.semibold))
                Text((app.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // MARK: review

    private var review: some View {
        let selected = items.filter { chosen.contains($0.id) }
        let adminCount = selected.filter(\.needsAdmin).count
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                if let official {
                    Notice(icon: "wrench.and.screwdriver", tint: .accentTeal,
                           text: "\(app.name) punya uninstaller resmi. Sebaiknya jalankan itu dulu agar layanan latar belakangnya ikut dimatikan dengan benar, lalu bersihkan sisanya di sini.") {
                        Button("Buka Uninstaller") { NSWorkspace.shared.open(URL(fileURLWithPath: official)) }
                    }
                }
                if !running.isEmpty {
                    Notice(icon: "exclamationmark.triangle.fill", tint: .orange,
                           text: "\(running.compactMap(\.localizedName).joined(separator: ", ")) sedang berjalan dan akan diminta keluar. Jika masih terbuka (misalnya menunggu Anda menyimpan pekerjaan), uninstall dibatalkan.")
                }
            }
            .padding(.horizontal, 20).padding(.top, official != nil || !running.isEmpty ? 12 : 0)

            List {
                section("Aplikasi", items.filter { $0.match == .app })
                section("Sisa file", items.filter { $0.match == .sure })
                section("Mungkin terkait", items.filter { $0.match == .maybe },
                        note: "Nama mirip atau dari vendor yang sama. Bisa jadi dipakai aplikasi lain dari vendor ini, jadi tidak dicentang otomatis.")
            }
            .listStyle(.inset)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if adminCount > 0 {
                    Label("\(adminCount) item milik sistem: butuh password admin dan langsung dihapus permanen.",
                          systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Toggle("Hapus permanen (tidak lewat Sampah)", isOn: $permanent).toggleStyle(.checkbox)
                    Spacer()
                    Text("\(selected.count) item · \(Fmt.size(selected.reduce(0) { $0 + $1.size }))")
                        .foregroundStyle(.secondary).monospacedDigit()
                    Button("Batal") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Uninstall") { start(selected) }
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
                    Button(all ? "Batal Pilih" : "Pilih Semua") {
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
                        .help("Milik sistem, butuh password admin")
                }
                Text(Fmt.size(it.size)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .contextMenu { Button("Tampilkan di Finder") { model.reveal([it.path]) } }
    }

    // MARK: result

    private func result(_ r: DeleteResult) -> some View {
        VStack(spacing: 14) {
            Image(systemName: r.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(r.failed.isEmpty ? Color.accentTeal : .orange)
            Text(r.failed.isEmpty ? "\(app.name) sudah dihapus" : "Sebagian tidak bisa dihapus")
                .font(.title3.weight(.semibold))
            Text("\(r.removed.count) item · \(Fmt.size(r.freed)) dibebaskan")
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
            Button("Tutup") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: actions

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
                r = DeleteResult(failed: selected.map { ($0.path, "\(names) masih berjalan. Simpan pekerjaan dan tutup aplikasinya, lalu coba lagi.") })
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
