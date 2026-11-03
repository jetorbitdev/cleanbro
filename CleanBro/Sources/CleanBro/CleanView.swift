import SwiftUI

struct CleanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.cleanPhase {
            case .idle: idle
            case .scanning: scanning
            case .done: results
            case .finished: finished
            }
        }
        .navigationTitle("Pembersihan")
    }

    private var idle: some View {
        VStack(spacing: 18) {
            Circle()
                .strokeBorder(Color.accentTeal.opacity(0.15), lineWidth: 10)
                .frame(width: 148, height: 148)
                .overlay(Text("Siap").foregroundStyle(.secondary))
            Text("Temukan file sampah di Mac Anda")
                .font(.system(size: 24, weight: .semibold))
            Text("Cache, log, data developer, sisa unduhan, dan isi Sampah akan dipindai. Tidak ada yang dihapus sebelum Anda konfirmasi.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Pindai") { model.startJunkScan() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanning: some View {
        let p = model.junkProgress
        let frac = p.total > 0 ? Double(p.done) / Double(p.total) : 0
        return VStack(spacing: 16) {
            Text("\(Int(frac * 100))%")
                .font(.system(size: 48, weight: .light)).monospacedDigit()
            ProgressView(value: frac).frame(width: 360)
            Text((p.current as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 460)
            StopButton(stopping: model.junkStopping) { model.cancelJunkScan() }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.size(model.junkSelectedSize))
                    .font(.system(size: 32, weight: .semibold)).monospacedDigit()
                Text("bisa dibersihkan").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 12)

            if model.junkPartial {
                PartialBanner(text: "Pemindaian dihentikan. Daftar ini hanya berisi item yang sudah selesai diukur.") {
                    model.startJunkScan()
                }
                .padding(.horizontal, 28).padding(.bottom, 8)
            }

            List {
                ForEach(model.junk) { cat in
                    JunkCategoryRow(category: cat)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: 10) {
                Button("Pindai Ulang") { model.startJunkScan() }
                Spacer()
                Button("Bersihkan \(Fmt.size(model.junkSelectedSize))") { model.requestJunkClean() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.junkSelectedSize == 0)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
            .background(.bar)
        }
    }

    private var finished: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(Color.accentTeal)
            Text("Selesai").font(.headline).foregroundStyle(Color.accentTeal)
            Text("\(Fmt.size(model.freed)) \(model.lastDeleteMode == .trash ? "dipindahkan ke Sampah" : "dikosongkan")")
                .font(.system(size: 28, weight: .semibold))
            Text(model.lastDeleteMode == .trash
                 ? "File bisa dipulihkan dari Sampah. Kosongkan Sampah untuk membebaskan ruang disk."
                 : "File dihapus permanen (deep clean), tanpa melewati Sampah.")
                .foregroundStyle(.secondary)
            if !model.lastKept.isEmpty {
                Label("\(model.lastKept.count) item (\(Fmt.size(model.lastKept.reduce(0) { $0 + $1.size }))) sudah ada di Sampah dan dibiarkan. Kosongkan Sampah untuk menghapusnya permanen.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
            }
            if !model.lastFailures.isEmpty {
                FailureList(failures: model.lastFailures).frame(maxWidth: 520)
            }
            HStack {
                Button("Kembali") { model.cleanPhase = .idle }
                if model.lastDeleteMode == .trash, (model.trashCount ?? 0) > 0 {
                    Button("Kosongkan Sampah…") { model.requestEmptyTrash() }
                }
            }
            .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JunkCategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: JunkCategory
    @StateVar private var expanded = false

    var body: some View {
        let ids = Set(category.items.map(\.path))
        let selected = ids.intersection(model.junkSelected)
        let all = !ids.isEmpty && selected.count == ids.count

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Toggle("", isOn: Binding(
                    get: { all },
                    set: { on in if on { model.junkSelected.formUnion(ids) } else { model.junkSelected.subtract(ids) } }
                ))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(ids.isEmpty)

                Image(systemName: category.icon)
                    .frame(width: 22).foregroundStyle(Color.accentTeal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name).font(.system(size: 14, weight: .medium))
                    Text(category.desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if category.note != nil {
                    Button("Beri Akses…") { model.askFullDiskAccess = true }
                        .controlSize(.small)
                }
                if !selected.isEmpty && !all {
                    Text("\(selected.count)/\(ids.count)").font(.caption).foregroundStyle(.secondary)
                }
                Text(Fmt.size(category.size)).monospacedDigit()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(ids.isEmpty)
            }
            .padding(.vertical, 8)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(category.items.prefix(300)) { item in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { model.junkSelected.contains(item.path) },
                                set: { on in if on { model.junkSelected.insert(item.path) } else { model.junkSelected.remove(item.path) } }
                            ))
                            .toggleStyle(.checkbox).labelsHidden()
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.size(item.size)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Tampilkan di Finder") { model.reveal([item.path]) }
                        }
                    }
                    if category.items.count > 300 {
                        Text("… dan \(category.items.count - 300) item lainnya")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                    }
                }
                .padding(.leading, 36)
                .padding(.bottom, 8)
            }
        }
    }
}

struct FailureList: View {
    let failures: [(path: String, reason: String)]
    var body: some View {
        DisclosureGroup("\(failures.count) item tidak bisa dihapus") {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(failures.prefix(100).enumerated()), id: \.offset) { _, f in
                        Text("\((f.path as NSString).abbreviatingWithTildeInPath) — \(f.reason)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
        .padding(.top, 8)
    }
}
