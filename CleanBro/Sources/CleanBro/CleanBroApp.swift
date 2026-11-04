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
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .en

    init() {
        // Before AppKit builds its menus, so they match the chosen language.
        AppLanguage.atLaunch.applyToSystemMenus()
    }

    var body: some Scene {
        WindowGroup("CleanBro") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 580)
                .tint(.accentTeal)
                .modifier(AppearanceSync())
                .environment(\.locale, language.locale)
                .id(language)
        }
        .defaultSize(width: 1080, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu(L("Scan", "Pindai")) {
                Button(L("Scan Folder…", "Pindai Folder…")) { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button(L("Rescan", "Pindai Ulang")) { model.startAnalysis() }
                    .keyboardShortcut("r")
                    .disabled(model.scanState == .scanning)
                Divider()
                Button(L("Empty Trash…", "Kosongkan Sampah…")) { model.requestEmptyTrash() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.isDeleting)
            }
            CommandGroup(after: .toolbar) {
                AppearancePicker()
                    .pickerStyle(.inline)
                Divider()
            }
        }

        Settings {
            TabView {
                GeneralSettings()
                    .tabItem { Label(L("General", "Umum"), systemImage: "gearshape") }
                SkipSettings()
                    .tabItem { Label(L("Always Skip", "Selalu Lewati"), systemImage: "folder.badge.minus") }
            }
            .environment(model)
            .tint(.accentTeal)
            .environment(\.locale, language.locale)
            .id(language)
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
                case .home: HomeView()
                case .clean: CleanView()
                case .apps: AppsView()
                case .brew: HomebrewView()
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
        .overlay { if let busy = model.brewBusy { BrewBusyOverlay(text: busy) } }
        .alert(L("Homebrew Reported an Error", "Homebrew melaporkan error"),
               isPresented: Binding(get: { model.brewError != nil }, set: { if !$0 { model.brewError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.brewError ?? "")
        }
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
            Section(L("Tools", "Alat")) {
                row(.home, L("Home", "Beranda"), "house", "")
                row(.clean, L("Cleanup", "Pembersihan"), "sparkles",
                    model.cleanPhase == .done ? Fmt.size(model.junkSelectedSize) : "")
                row(.apps, L("Uninstall Apps", "Uninstall Aplikasi"), "trash.square",
                    model.apps.isEmpty ? "" : String(model.apps.count))
                row(.brew, "Homebrew", "mug",
                    model.brewPackages.isEmpty ? "" : String(model.brewPackages.count))
            }
            Section(L("Analysis", "Analisis")) {
                row(.usage, L("Disk Usage", "Penggunaan Disk"), "chart.bar.doc.horizontal",
                    model.tree.map { Fmt.size($0.size) } ?? "")
                row(.large, L("Large Files", "File Besar"), "doc.badge.arrow.up",
                    model.tree == nil ? "" : String(model.largeFileStats.count))
                row(.stale, L("Not Modified Lately", "Lama Tak Diubah"), "clock.arrow.circlepath", "")
                row(.dupes, L("Duplicate Files", "File Duplikat"), "doc.on.doc",
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
                Text(L("\(Fmt.size(model.volumeFree)) free", "\(Fmt.size(model.volumeFree)) kosong")).foregroundStyle(.secondary)
                AppearanceToggle()
            }
            .font(.system(size: 12))
            ProgressView(value: frac).tint(frac > 0.9 ? .red : .accentTeal)
            Text(L("\(Fmt.size(used)) of \(Fmt.size(model.volumeTotal)) used", "\(Fmt.size(used)) dari \(Fmt.size(model.volumeTotal)) terpakai"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider().padding(.vertical, 2)
            HStack(spacing: 6) {
                Label(L("Trash", "Sampah"), systemImage: (model.trashCount ?? 0) > 0 ? "trash.fill" : "trash")
                Spacer()
                Text(model.trashSize.map(Fmt.size) ?? "—").foregroundStyle(.secondary).monospacedDigit()
                Button(L("Empty", "Kosongkan")) { model.requestEmptyTrash() }
                    .controlSize(.small)
                    .disabled(model.trashCount == 0 || model.isDeleting)
            }
            .font(.system(size: 12))
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
                Text(L("Cleaning…", "Membersihkan…")).font(.headline)
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
        content.alert(L("CleanBro Needs Full Disk Access", "CleanBro butuh Full Disk Access"), isPresented: shown) {
            Button(L("Open Settings", "Buka Pengaturan")) { model.openFullDiskAccessSettings() }
            Button(L("Later", "Nanti"), role: .cancel) {}
        } message: {
            Text(L("Without this permission, the Trash and some folders in Library can't be read.\n\nIn System Settings › Privacy & Security › Full Disk Access, turn on CleanBro. If it's not in the list, drag CleanBro from the open Finder window into the list. Then reopen CleanBro.",
                   "Tanpa izin ini, Sampah dan sebagian folder di Library tidak bisa dibaca.\n\nDi Pengaturan Sistem › Privasi & Keamanan › Full Disk Access, nyalakan CleanBro. Kalau belum ada di daftar, seret CleanBro dari jendela Finder yang terbuka ke daftar itu. Setelah itu buka ulang CleanBro."))
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
            p.map { p in
                let n = p.items.count, size = Fmt.size(p.total)
                return p.emptiesTrash
                    ? L("Empty Trash: \(n) \(n == 1 ? "item" : "items") (\(size))?", "Kosongkan Sampah \(n) item (\(size))?")
                    : L("Delete \(n) \(n == 1 ? "item" : "items") (\(size))?", "Hapus \(n) item (\(size))?")
            } ?? "",
            isPresented: shown, titleVisibility: .visible, presenting: p
        ) { p in
            if p.emptiesTrash {
                Button(L("Empty Trash", "Kosongkan Sampah"), role: .destructive) { model.perform(p, mode: .permanent) }
            } else {
                Button(L("Move to Trash", "Pindahkan ke Sampah")) { model.perform(p, mode: .trash) }
                Button(L("Delete Permanently (Deep Clean)", "Hapus Permanen (Deep Clean)"), role: .destructive) { model.perform(p, mode: .permanent) }
            }
            Button(L("Cancel", "Batal"), role: .cancel) {}
        } message: { p in
            if p.emptiesTrash {
                Text(L("All items in the Trash, including the Trash on external disks, will be permanently deleted. This can't be undone.",
                       "Semua item di Sampah, termasuk Sampah di disk eksternal, akan dihapus permanen. Tindakan ini tidak bisa dibatalkan."))
            } else {
                let inTrash = p.items.filter { DeepCleaner.isInTrash($0.path) }
                let note = inTrash.isEmpty ? "" :
                    L("\n\n\(inTrash.count) \(inTrash.count == 1 ? "item" : "items") (\(Fmt.size(inTrash.reduce(0) { $0 + $1.size }))) already in the Trash: Move to Trash leaves them, only Delete Permanently removes them.",
                      "\n\n\(inTrash.count) item (\(Fmt.size(inTrash.reduce(0) { $0 + $1.size }))) sudah ada di Sampah: Pindahkan ke Sampah membiarkannya, hanya Hapus Permanen yang menghapusnya.")
                Text(L("Items are moved to the Trash and can still be restored; disk space is freed only after the Trash is emptied. Delete Permanently removes files and entire folder contents right away, including locked ones, and can't be undone.",
                       "Item dipindahkan ke Sampah dan masih bisa dipulihkan; ruang disk baru kosong setelah Sampah dikosongkan. Hapus Permanen langsung menghapus file dan seluruh isi folder, termasuk yang terkunci, dan tidak bisa dibatalkan.") + note)
            }
        }
    }
}
