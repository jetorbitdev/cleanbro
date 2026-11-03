import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CleanBroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateVar private var model = AppModel()

    var body: some Scene {
        WindowGroup("CleanBro") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 580)
                .tint(.accentTeal)
        }
        .defaultSize(width: 1080, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Pindai") {
                Button("Pindai Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Pindai Ulang") { model.startAnalysis() }
                    .keyboardShortcut("r")
                    .disabled(model.scanState == .scanning)
                Divider()
                Button("Kosongkan Sampah…") { model.requestEmptyTrash() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.isDeleting)
            }
        }

        Settings {
            SkipSettings()
                .environment(model)
                .tint(.accentTeal)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch model.tool {
                case .clean: CleanView()
                case .apps: AppsView()
                case .usage: AnalysisGate { DiskUsageView() }
                case .large: AnalysisGate { LargeFilesView() }
                case .stale: AnalysisGate { StaleView() }
                case .dupes: AnalysisGate { DuplicatesView() }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
        }
        .overlay(alignment: .bottom) { ToastView() }
        .overlay { if model.isDeleting { DeletingOverlay() } }
        .modifier(DeleteConfirmation())
        .modifier(FullDiskAccessPrompt())
        .sheet(item: Binding(get: { model.uninstallTarget }, set: { model.uninstallTarget = $0 })) { app in
            UninstallSheet(app: app).environment(model)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<Tool?>(get: { model.tool }, set: { if let t = $0 { model.tool = t } })
        List(selection: selection) {
            Section("Alat") {
                row(.clean, "Pembersihan", "sparkles",
                    model.cleanPhase == .done ? Fmt.size(model.junkSelectedSize) : "")
                row(.apps, "Uninstall Aplikasi", "trash.square",
                    model.apps.isEmpty ? "" : String(model.apps.count))
            }
            Section("Analisis") {
                row(.usage, "Penggunaan Disk", "chart.bar.doc.horizontal",
                    model.tree.map { Fmt.size($0.size) } ?? "")
                row(.large, "File Besar", "doc.badge.arrow.up",
                    model.tree == nil ? "" : String(model.files.filter { $0.size >= 100 << 20 }.count))
                row(.stale, "Lama Tak Diubah", "clock.arrow.circlepath", "")
                row(.dupes, "File Duplikat", "doc.on.doc",
                    model.dupeState == .done ? Fmt.size(model.dupeWasted) : "")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { VolumeBox().padding(16) }
    }

    private func row(_ t: Tool, _ title: String, _ icon: String, _ meta: String) -> some View {
        NavigationLink(value: t) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text(meta).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct VolumeBox: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let used = max(0, model.volumeTotal - model.volumeFree)
        let frac = model.volumeTotal > 0 ? Double(used) / Double(model.volumeTotal) : 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.volumeName).fontWeight(.medium)
                Spacer()
                Text("\(Fmt.size(model.volumeFree)) kosong").foregroundStyle(.secondary)
            }
            .font(.caption)
            ProgressView(value: frac).tint(frac > 0.9 ? .red : .accentTeal)
            Text("\(Fmt.size(used)) dari \(Fmt.size(model.volumeTotal)) terpakai")
                .font(.caption2).foregroundStyle(.secondary)
            Divider().padding(.vertical, 2)
            HStack(spacing: 6) {
                Label("Sampah", systemImage: (model.trashCount ?? 0) > 0 ? "trash.fill" : "trash")
                Spacer()
                Text(model.trashSize.map(Fmt.size) ?? "—").foregroundStyle(.secondary).monospacedDigit()
                Button("Kosongkan") { model.requestEmptyTrash() }
                    .controlSize(.small)
                    .disabled(model.trashCount == 0 || model.isDeleting)
            }
            .font(.caption)
        }
        .onAppear { model.refreshVolume() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshVolume()
            model.refreshTrash()
        }
    }
}

// MARK: - Toast / overlays / confirmation

struct ToastView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let t = model.toast {
            Text(t)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 70)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeOut, value: model.toast)
        }
    }
}

struct DeletingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Membersihkan…").font(.headline)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct FullDiskAccessPrompt: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let shown = Binding(get: { model.askFullDiskAccess }, set: { model.askFullDiskAccess = $0 })
        content.alert("CleanBro butuh Full Disk Access", isPresented: shown) {
            Button("Buka Pengaturan") { model.openFullDiskAccessSettings() }
            Button("Nanti", role: .cancel) {}
        } message: {
            Text("Tanpa izin ini, Sampah dan sebagian folder di Library tidak bisa dibaca.\n\nDi Pengaturan Sistem › Privasi & Keamanan › Full Disk Access, nyalakan CleanBro. Kalau belum ada di daftar, seret CleanBro dari jendela Finder yang terbuka ke daftar itu. Setelah itu buka ulang CleanBro.")
        }
    }
}

struct DeleteConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let shown = Binding(get: { model.pendingDelete != nil },
                            set: { if !$0 { model.pendingDelete = nil } })
        let p = model.pendingDelete
        content.confirmationDialog(
            p.map { "\($0.emptiesTrash ? "Kosongkan Sampah" : "Hapus") \($0.items.count) item (\(Fmt.size($0.total)))?" } ?? "",
            isPresented: shown, titleVisibility: .visible, presenting: p
        ) { p in
            if p.emptiesTrash {
                Button("Kosongkan Sampah", role: .destructive) { model.perform(p, mode: .permanent) }
            } else {
                Button("Pindahkan ke Sampah") { model.perform(p, mode: .trash) }
                Button("Hapus Permanen (Deep Clean)", role: .destructive) { model.perform(p, mode: .permanent) }
            }
            Button("Batal", role: .cancel) {}
        } message: { p in
            if p.emptiesTrash {
                Text("Semua item di Sampah, termasuk Sampah di disk eksternal, akan dihapus permanen. Tindakan ini tidak bisa dibatalkan.")
            } else {
                let inTrash = p.items.filter { DeepCleaner.isInTrash($0.path) }
                let note = inTrash.isEmpty ? "" :
                    "\n\n\(inTrash.count) item (\(Fmt.size(inTrash.reduce(0) { $0 + $1.size }))) sudah ada di Sampah: Pindahkan ke Sampah membiarkannya, hanya Hapus Permanen yang menghapusnya."
                Text("Item dipindahkan ke Sampah dan masih bisa dipulihkan; ruang disk baru kosong setelah Sampah dikosongkan. Hapus Permanen langsung menghapus file dan seluruh isi folder, termasuk yang terkunci, dan tidak bisa dibatalkan." + note)
            }
        }
    }
}
