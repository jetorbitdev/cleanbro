import SwiftUI

private let MB: Int64 = 1 << 20
private let GB: Int64 = 1 << 30

// MARK: - Duplicate files

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @StateVar private var minSize: Int64 = MB
    @StateVar private var query = ""

    private var groups: [DupeGroup] {
        let q = query.lowercased()
        return model.dupes.filter { g in
            g.size >= minSize && (q.isEmpty || g.items.contains { $0.name.lowercased().contains(q) })
        }
    }

    var body: some View {
        let visible = groups
        Group {
            switch model.dupeState {
            case .idle: idle
            case .scanning: scanning
            case .done: results(visible)
            }
        }
        .navigationTitle("File Duplikat")
        .navigationSubtitle(model.dupeState == .done
                            ? "\(visible.count) grup · \(Fmt.size(visible.reduce(0) { $0 + $1.wasted })) bisa dihemat"
                            : "")
        .searchable(text: $query, placement: .toolbar, prompt: "Cari nama file")
        .toolbar {
            ToolbarItem {
                Picker("Minimal", selection: $minSize) {
                    Text("≥ 1 MB").tag(MB)
                    Text("≥ 10 MB").tag(10 * MB)
                    Text("≥ 100 MB").tag(100 * MB)
                    Text("≥ 1 GB").tag(GB)
                }
                .help("Ukuran minimal per file")
                .disabled(model.dupeState != .done)
            }
        }
    }

    private var idle: some View {
        @Bindable var model = model
        return VStack(spacing: 18) {
            Circle()
                .strokeBorder(Color.accentTeal.opacity(0.15), lineWidth: 10)
                .frame(width: 148, height: 148)
                .overlay(Image(systemName: "doc.on.doc").font(.system(size: 40)).foregroundStyle(.secondary))
            Text("Cari file duplikat")
                .font(.system(size: 24, weight: .semibold))
            Text("CleanBro membandingkan isi \(Fmt.count(Int64(model.files.count))) file berukuran ≥ 1 MB di \((model.scanRoot.path as NSString).abbreviatingWithTildeInPath). Hanya file dengan ukuran sama yang dibaca, dan isinya dicocokkan byte demi byte lewat SHA-256.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            Toggle("Lewati Library, folder sistem, paket aplikasi, dan pustaka Foto/Musik", isOn: $model.dupeSkipProtected)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .help("File di dalamnya sering sengaja kembar; menghapusnya bisa merusak aplikasi")
            Button("Cari Duplikat") { model.startDupeScan() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanning: some View {
        let p = model.dupeProgress
        let frac = p.total > 0 ? Double(p.done) / Double(p.total) : 0
        return VStack(spacing: 16) {
            Text("\(Int(frac * 100))%")
                .font(.system(size: 48, weight: .light)).monospacedDigit()
            ProgressView(value: frac).frame(width: 360)
            Text("\(Fmt.count(Int64(p.done))) dari \(Fmt.count(Int64(p.total))) file dicek · \(Fmt.size(p.bytes)) dibaca")
                .foregroundStyle(.secondary).monospacedDigit()
            Text((p.current as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 460)
            StopButton(stopping: model.dupeStopping) { model.cancelDupeScan() }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func results(_ visible: [DupeGroup]) -> some View {
        VStack(spacing: 0) {
            if model.dupePartial {
                PartialBanner(text: "Pencarian dihentikan. Daftar ini hanya berisi grup yang sudah selesai dicocokkan.") {
                    model.startDupeScan()
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                Divider()
            }
            if visible.isEmpty {
                EmptyRows(text: model.dupes.isEmpty
                          ? "Tidak ada file duplikat. 🎉"
                          : "Tidak ada duplikat yang cocok dengan filter ini.")
            } else {
                List {
                    ForEach(visible) { g in
                        Section {
                            ForEach(g.items) { item in
                                DupeRow(item: item, group: g, marked: model.marks(for: .dupes))
                            }
                        } header: {
                            DupeHeader(group: g)
                        }
                    }
                }
                .listStyle(.inset)
            }
            DupeBar(groups: visible, marked: model.marks(for: .dupes))
        }
    }
}

private struct DupeHeader: View {
    let group: DupeGroup
    var body: some View {
        HStack(spacing: 8) {
            Text(group.items.first?.name ?? "").fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
            Text("\(group.items.count) salinan × \(Fmt.size(group.size))").foregroundStyle(.secondary)
            Spacer()
            Text("hemat \(Fmt.size(group.wasted))").foregroundStyle(Color.accentTeal).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

private struct DupeRow: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let group: DupeGroup
    @Binding var marked: Set<String>

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { marked.contains(item.id) },
                set: { on in if on { marked.insert(item.id) } else { marked.remove(item.id) } }
            ))
            .toggleStyle(.checkbox).labelsHidden()
            Text(item.badge)
                .font(.system(size: 9, weight: .bold)).tracking(0.4)
                .foregroundStyle(item.kind.tint)
                .frame(width: 38, height: 24)
                .background(item.kind.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(item.location).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if item.id == group.items.first?.id {
                Text("Terlama").font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(.quaternary))
            }
            Text(Fmt.date(item.modified)).foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.reveal([item.path]) }
        .contextMenu {
            Button("Tampilkan di Finder") { model.reveal([item.path]) }
            Button("Simpan yang Ini Saja") {
                marked.formUnion(group.items.map(\.id))
                marked.remove(item.id)
            }
        }
    }
}

// MARK: - Bottom bar with auto-select

private struct DupeBar: View {
    @Environment(AppModel.self) private var model
    let groups: [DupeGroup]
    @Binding var marked: Set<String>

    var body: some View {
        let chosen = groups.flatMap(\.items).filter { marked.contains($0.id) }
        let total = chosen.reduce(Int64(0)) { $0 + $1.size }
        let wiped = groups.filter { g in g.items.allSatisfy { marked.contains($0.id) } }.count

        HStack(spacing: 10) {
            Text("\(chosen.count) dipilih")
            if !chosen.isEmpty { Text(Fmt.size(total)).foregroundStyle(.secondary).monospacedDigit() }
            Menu("Pilih Otomatis") {
                Button("Sisakan yang terlama") { keepOne { $0.modified < $1.modified } }
                Button("Sisakan yang terbaru") { keepOne { $0.modified > $1.modified } }
                Button("Sisakan jalur terpendek") { keepOne { $0.path.count < $1.path.count } }
                Divider()
                Button("Hapus Semua Centang") { marked.subtract(groups.flatMap(\.items).map(\.id)) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(groups.isEmpty)
            if wiped > 0 {
                Label("Semua salinan di \(wiped) grup tercentang", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Tidak ada salinan yang tersisa untuk grup ini setelah dihapus")
            }
            Spacer()
            Button("Pindai Ulang") { model.startDupeScan() }
            Button {
                model.requestDelete(chosen, from: .dupes)
            } label: {
                Label("Hapus…", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(chosen.isEmpty)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Marks every copy except the first one by `keepFirst` in each visible group.
    private func keepOne(by keepFirst: (Item, Item) -> Bool) {
        for g in groups {
            let ordered = g.items.sorted(by: keepFirst)
            marked.subtract(g.items.map(\.id))
            marked.formUnion(ordered.dropFirst().map(\.id))
        }
    }
}
