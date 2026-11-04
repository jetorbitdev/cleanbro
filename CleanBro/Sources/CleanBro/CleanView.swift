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
        .navigationTitle(L("Cleanup", "Pembersihan"))
    }

    private var idle: some View {
        VStack(spacing: 18) {
            Circle()
                .strokeBorder(Color.accentTeal.opacity(0.15), lineWidth: 10)
                .frame(width: 148, height: 148)
                .overlay(Text(L("Ready", "Siap")).foregroundStyle(.secondary))
            Text(L("Find junk files on your Mac", "Temukan file sampah di Mac Anda"))
                .font(.system(size: 24, weight: .semibold))
            Text(L("Caches, logs, developer data, leftover downloads, and Trash contents will be scanned. Nothing is deleted until you confirm.",
                   "Cache, log, data developer, sisa unduhan, dan isi Sampah akan dipindai. Tidak ada yang dihapus sebelum Anda konfirmasi."))
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button(L("Scan", "Pindai")) { model.startJunkScan() }
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
                Text(L("can be cleaned up", "bisa dibersihkan")).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 12)

            if model.junkPartial {
                PartialBanner(text: L("Scan stopped. This list only contains items that were fully measured.",
                                      "Pemindaian dihentikan. Daftar ini hanya berisi item yang sudah selesai diukur.")) {
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
                Button(L("Rescan", "Pindai Ulang")) { model.startJunkScan() }
                Spacer()
                Button(L("Clean \(Fmt.size(model.junkSelectedSize))", "Bersihkan \(Fmt.size(model.junkSelectedSize))")) { model.requestJunkClean() }
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
            Text(L("Done", "Selesai")).font(.headline).foregroundStyle(Color.accentTeal)
            Text(model.lastDeleteMode == .trash
                 ? L("\(Fmt.size(model.freed)) moved to Trash", "\(Fmt.size(model.freed)) dipindahkan ke Sampah")
                 : L("\(Fmt.size(model.freed)) freed", "\(Fmt.size(model.freed)) dikosongkan"))
                .font(.system(size: 28, weight: .semibold))
            Text(model.lastDeleteMode == .trash
                 ? L("Files can be restored from the Trash. Empty the Trash to free up disk space.",
                     "File bisa dipulihkan dari Sampah. Kosongkan Sampah untuk membebaskan ruang disk.")
                 : L("Files were permanently deleted (Deep Clean), bypassing the Trash.",
                     "File dihapus permanen (deep clean), tanpa melewati Sampah."))
                .foregroundStyle(.secondary)
            if !model.lastKept.isEmpty {
                let keptCount = model.lastKept.count
                let keptSize = Fmt.size(model.lastKept.reduce(0) { $0 + $1.size })
                Label(keptCount == 1
                      ? L("1 item (\(keptSize)) is already in the Trash and was left alone. Empty the Trash to delete it permanently.",
                          "\(keptCount) item (\(keptSize)) sudah ada di Sampah dan dibiarkan. Kosongkan Sampah untuk menghapusnya permanen.")
                      : L("\(keptCount) items (\(keptSize)) are already in the Trash and were left alone. Empty the Trash to delete them permanently.",
                          "\(keptCount) item (\(keptSize)) sudah ada di Sampah dan dibiarkan. Kosongkan Sampah untuk menghapusnya permanen."),
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
            }
            if !model.lastFailures.isEmpty {
                FailureList(failures: model.lastFailures).frame(maxWidth: 520)
            }
            HStack {
                Button(L("Back", "Kembali")) { model.cleanPhase = .idle }
                if model.lastDeleteMode == .trash, (model.trashCount ?? 0) > 0 {
                    Button(L("Empty Trash…", "Kosongkan Sampah…")) { model.requestEmptyTrash() }
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
                    Button(L("Grant Access…", "Beri Akses…")) { model.askFullDiskAccess = true }
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
                            Button(L("Show in Finder", "Tampilkan di Finder")) { model.reveal([item.path]) }
                        }
                    }
                    if category.items.count > 300 {
                        let more = category.items.count - 300
                        Text(more == 1
                             ? L("… and 1 more item", "… dan \(more) item lainnya")
                             : L("… and \(more) more items", "… dan \(more) item lainnya"))
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
        DisclosureGroup(failures.count == 1
                        ? L("1 item couldn't be deleted", "\(failures.count) item tidak bisa dihapus")
                        : L("\(failures.count) items couldn't be deleted", "\(failures.count) item tidak bisa dihapus")) {
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
