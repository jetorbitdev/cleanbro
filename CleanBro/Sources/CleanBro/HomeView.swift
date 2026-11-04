import SwiftUI

// MARK: - Squarified treemap layout

enum Treemap {
    /// Rectangles that fill `rect`, one per size (largest first), with areas
    /// proportional to the sizes and aspect ratios kept close to square.
    static func layout(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: sizes.count)
        let total = sizes.reduce(0) { $0 + max(0, $1) }
        guard total > 0, rect.width > 1, rect.height > 1 else { return out }
        let scale = Double(rect.width * rect.height) / total
        let areas = sizes.map { max(0, $0) * scale }
        var r = rect
        var i = 0
        while i < areas.count {
            let side = Double(min(r.width, r.height))
            guard side > 0 else { break }
            var j = i + 1
            var sum = areas[i], lo = areas[i], hi = areas[i]
            var current = worst(sum, lo, hi, side)
            while j < areas.count {
                let a = areas[j]
                let next = worst(sum + a, min(lo, a), max(hi, a), side)
                if next > current { break }
                sum += a; lo = min(lo, a); hi = max(hi, a); current = next
                j += 1
            }
            guard sum > 0 else { break }
            let thick = sum / side
            if r.width >= r.height {
                var y = Double(r.minY)
                for k in i..<j {
                    let h = areas[k] / thick
                    out[k] = CGRect(x: Double(r.minX), y: y, width: thick, height: h)
                    y += h
                }
                r = CGRect(x: r.minX + thick, y: r.minY, width: max(0, r.width - thick), height: r.height)
            } else {
                var x = Double(r.minX)
                for k in i..<j {
                    let w = areas[k] / thick
                    out[k] = CGRect(x: x, y: Double(r.minY), width: w, height: thick)
                    x += w
                }
                r = CGRect(x: r.minX, y: r.minY + thick, width: r.width, height: max(0, r.height - thick))
            }
            i = j
        }
        return out
    }

    /// Worst aspect ratio of a row with total area `sum`, smallest `lo`, largest `hi`.
    private static func worst(_ sum: Double, _ lo: Double, _ hi: Double, _ side: Double) -> Double {
        guard lo > 0, sum > 0 else { return .infinity }
        let s2 = side * side, sum2 = sum * sum
        return max(s2 * hi / sum2, sum2 / (s2 * lo))
    }
}

// MARK: - Blocks shown in the map

enum MapFocus: Hashable {
    /// whole disk, grouped into categories (only when "/" was scanned)
    case overview
    case category(String)
    case node(String)
}

struct MapBlock: Identifiable {
    let id: String
    let name: String
    let size: Int64
    /// real file or folder; nil for categories and "Lainnya"
    var path: String?
    /// where a double-click goes
    var target: MapFocus?
    var color: Color = .gray
    /// light fill, dark text
    var light = false
    /// white overlay that tells nested blocks apart
    var shade: Double = 0
    var children: [MapBlock] = []
}

private enum Category: String, CaseIterable {
    case users, other, system, apps

    var title: String {
        switch self {
        case .users: L("Users", "Pengguna")
        case .other: L("Other Space", "Ruang lain")
        case .system: L("System", "Sistem")
        case .apps: L("Applications", "Aplikasi")
        }
    }

    var color: Color {
        switch self {
        case .users: Color(red: 0.23, green: 0.42, blue: 0.62)
        case .other: Color(white: 0.77)
        case .system: Color(red: 0.42, green: 0.63, blue: 0.47)
        case .apps: Color(red: 0.72, green: 0.58, blue: 0.36)
        }
    }

    var help: String {
        switch self {
        case .users: L("User folders in /Users", "Folder pengguna di /Users")
        case .other: L("Space in use that the scan couldn't read: APFS snapshots, protected system files, swap, and other app data",
                       "Ruang terpakai yang tidak terbaca saat pemindaian: snapshot APFS, file sistem yang dilindungi, swap, dan data aplikasi lain")
        case .system: L("macOS, /Library, /private, /usr, and other system folders", "macOS, /Library, /private, /usr dan folder sistem lain")
        case .apps: L("Applications in /Applications", "Aplikasi di /Applications")
        }
    }
}

/// Builds the blocks of one map level from the scanned tree.
@MainActor
private struct MapBuilder {
    let model: AppModel
    let root: DirNode
    let filesByParent: [String: [FileEntry]]

    static let palette: [Color] = [
        Category.users.color, Category.system.color, Category.apps.color,
        Color(red: 0.52, green: 0.43, blue: 0.66), Color(red: 0.13, green: 0.52, blue: 0.53),
        Color(red: 0.71, green: 0.42, blue: 0.47), Color(red: 0.40, green: 0.46, blue: 0.56),
    ]

    var isDisk: Bool { root.path == "/" }

    func level(_ focus: MapFocus) -> [MapBlock] {
        switch focus {
        case .overview:
            return categories().map { cat, size, raw in
                var b = MapBlock(id: "cat:" + cat.rawValue, name: cat.title, size: size,
                                 target: cat == .other ? nil : .category(cat.rawValue),
                                 color: cat.color, light: cat == .other)
                if !raw.isEmpty {
                    b.children = shadeChildren(group(raw, total: size, max: 10, minFrac: 0.03, id: b.id), of: b)
                }
                return b
            }
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
        case .category(let key):
            guard let (_, size, raw) = categories().first(where: { $0.0.rawValue == key }) else { return [] }
            return nest(group(raw, total: size, max: 24, minFrac: 0.004, id: key))
        case .node(let path):
            guard let n = model.node(at: path) else { return [] }
            return nest(group(entries(n), total: n.size, max: 24, minFrac: 0.004, id: path))
        }
    }

    /// Size and contents of each disk category.
    private func categories() -> [(Category, Int64, [MapBlock])] {
        guard isDisk else { return [] }
        let users = root.children.first { $0.name == "Users" }
        let apps = root.children.first { $0.name == "Applications" }
        let home = NSHomeDirectory()

        var userRaw: [MapBlock] = []
        if let users {
            for b in entries(users) {
                if b.path == home, let h = model.node(at: home) { userRaw += entries(h) } else { userRaw.append(b) }
            }
        }
        let sysRaw = entries(root).filter { $0.path != users?.path && $0.path != apps?.path }
        let usersSize = users?.size ?? 0, appsSize = apps?.size ?? 0
        return [
            (.users, usersSize, userRaw),
            (.apps, appsSize, apps.map(entries) ?? []),
            (.system, max(0, root.size - usersSize - appsSize), sysRaw),
            (.other, max(0, model.volumeUsed - root.size), []),
        ]
    }

    /// Folders and (large) files directly inside `node`.
    func entries(_ node: DirNode) -> [MapBlock] {
        var out = node.children.filter { $0.size > 0 }.map { n in
            let leaf = n.children.isEmpty && (filesByParent[n.path]?.isEmpty ?? true)
            return MapBlock(id: n.path, name: n.name, size: n.size, path: n.path,
                            target: leaf || n.name.hasSuffix(".app") ? nil : .node(n.path))
        }
        out += (filesByParent[node.path] ?? []).map { f in
            MapBlock(id: f.path, name: (f.path as NSString).lastPathComponent, size: f.size, path: f.path)
        }
        return out
    }

    /// Keeps the biggest blocks and folds the rest, plus space not listed
    /// (small files, small folders), into one "Lainnya" block.
    private func group(_ items: [MapBlock], total: Int64, max maxCount: Int, minFrac: Double, id: String) -> [MapBlock] {
        let floor = Int64(Double(total) * minFrac)
        var kept: [MapBlock] = []
        var rest: Int64 = 0
        for b in items.sorted(by: { $0.size > $1.size }) {
            if kept.count < maxCount && b.size >= floor { kept.append(b) } else { rest += b.size }
        }
        rest += max(0, total - kept.reduce(0) { $0 + $1.size } - rest)
        if rest > 0 && Double(rest) >= Double(total) * 0.004 {
            kept.append(MapBlock(id: id + "#lainnya", name: L("Other", "Lainnya"), size: rest,
                                 color: Color(white: 0.84), light: true))
            kept.sort { $0.size > $1.size }
        }
        return kept
    }

    /// Colors the top blocks and fills each folder with its own contents.
    private func nest(_ top: [MapBlock]) -> [MapBlock] {
        var i = 0
        return top.map { b in
            var b = b
            if b.path != nil {
                b.color = Self.palette[i % Self.palette.count]
                i += 1
            }
            if let p = b.path, let n = model.node(at: p), b.target != nil {
                b.children = shadeChildren(group(entries(n), total: n.size, max: 10, minFrac: 0.03, id: p), of: b)
            }
            return b
        }
    }

    private func shadeChildren(_ kids: [MapBlock], of parent: MapBlock) -> [MapBlock] {
        kids.enumerated().map { i, k in
            var k = k
            if k.path != nil {
                k.color = parent.color
                k.light = parent.light
                k.shade = 0.12 + 0.07 * Double(i % 4)
            }
            return k
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @StateVar private var focus: MapFocus?
    @StateVar private var blocks: [MapBlock] = []
    @StateVar private var filesByParent: [String: [FileEntry]] = [:]
    @StateVar private var indexedRevision = -1
    @StateVar private var hovered: String?

    private var marks: Set<String> { model.marks[.home, default: []] }

    private var defaultFocus: MapFocus {
        guard let t = model.tree else { return .overview }
        return t.path == "/" ? .overview : .node(t.path)
    }

    /// The requested level, or the top one if it no longer exists.
    private var current: MapFocus {
        guard let f = focus else { return defaultFocus }
        switch f {
        case .overview: return model.tree?.path == "/" ? f : defaultFocus
        case .category: return model.tree?.path == "/" ? f : defaultFocus
        case .node(let p): return model.node(at: p) != nil ? f : defaultFocus
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            cards
                .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            AnalysisGate { map }
        }
        .navigationTitle(L("Home", "Beranda"))
        .onAppear {
            model.refreshVolume()
            // the home map is about the whole disk
            if model.tree == nil && model.scanState == .idle { model.scanRoot = URL(fileURLWithPath: "/") }
        }
        .task(id: Key(focus: current, rev: model.revision, used: model.volumeUsed, ready: model.scanState == .done)) {
            rebuild()
        }
        .onChange(of: model.tree?.path) { focus = nil }
    }

    private struct Key: Hashable { let focus: MapFocus; let rev: Int; let used: Int64; let ready: Bool }

    private func rebuild() {
        guard let tree = model.tree, model.scanState == .done else { blocks = []; return }
        if indexedRevision != model.revision {
            filesByParent = Dictionary(grouping: model.files, by: \.parentPath)
            indexedRevision = model.revision
        }
        blocks = MapBuilder(model: model, root: tree, filesByParent: filesByParent).level(current)
    }

    // MARK: header & cards

    private var header: some View {
        let crumbs = breadcrumbs
        return HStack(spacing: 6) {
            if crumbs.count > 1 {
                Button { focus = crumbs[crumbs.count - 2].focus } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("[", modifiers: .command)
                    .help(L("Back", "Kembali"))
            }
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                if i > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                Button(c.title) { focus = c.focus }
                    .buttonStyle(.plain)
                    .fontWeight(i == crumbs.count - 1 ? .semibold : .regular)
                    .foregroundStyle(i == crumbs.count - 1 ? .primary : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(L("\(Fmt.size(model.volumeUsed)) of \(Fmt.size(model.volumeTotal))",
                   "\(Fmt.size(model.volumeUsed)) dari \(Fmt.size(model.volumeTotal))"))
                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 14))
        .padding(.horizontal, 20).frame(height: 46)
    }

    private struct Crumb { let title: String; let focus: MapFocus }

    private var breadcrumbs: [Crumb] {
        guard let tree = model.tree, model.scanState == .done else { return [Crumb(title: model.volumeName, focus: .overview)] }
        let disk = tree.path == "/"
        var out = [Crumb(title: disk ? model.volumeName : (tree.path as NSString).abbreviatingWithTildeInPath,
                         focus: defaultFocus)]
        switch current {
        case .overview: break
        case .category(let k):
            if let c = Category(rawValue: k) { out.append(Crumb(title: c.title, focus: current)) }
        case .node(let p):
            guard let node = model.node(at: p) else { break }
            var chain: [DirNode] = []
            var n: DirNode? = node
            while let c = n, c !== tree { chain.insert(c, at: 0); n = c.parent }
            if disk, let first = chain.first {
                let cat: Category = first.name == "Users" ? .users : first.name == "Applications" ? .apps : .system
                out.append(Crumb(title: cat.title, focus: .category(cat.rawValue)))
                if cat != .system { chain.removeFirst() }
                // the users category already shows the contents of the home folder
                if cat == .users, chain.first?.path == NSHomeDirectory(), chain.count > 1 { chain.removeFirst() }
            }
            out += chain.map { Crumb(title: $0.name, focus: .node($0.path)) }
        }
        return out
    }

    private var cards: some View {
        let used = model.volumeUsed
        let frac = model.volumeTotal > 0 ? Double(used) / Double(model.volumeTotal) : 0
        let large = model.largeFileStats
        return HStack(spacing: 12) {
            StatCard(title: L("Free Space", "Ruang kosong"), value: Fmt.size(model.volumeFree),
                     detail: String(format: L("%.1f%% used", "%.1f%% terpakai"), frac * 100))
            switch model.cleanPhase {
            case .done:
                StatCard(title: L("Cleanable", "Bisa dibersihkan"), value: "± " + Fmt.size(model.junkSelectedSize),
                         detail: L("View junk ›", "Lihat sampah ›"), highlight: true) { model.tool = .clean }
            case .scanning:
                StatCard(title: L("Cleanable", "Bisa dibersihkan"), value: "…",
                         detail: L("Scanning for junk…", "Memindai sampah…"), highlight: true) {
                    model.tool = .clean
                }
            default:
                StatCard(title: L("Cleanable", "Bisa dibersihkan"), value: "—",
                         detail: L("Scan for junk ›", "Pindai sampah ›"), highlight: true) {
                    model.tool = .clean
                    if model.cleanPhase == .idle { model.startJunkScan() }
                }
            }
            if model.tree != nil {
                StatCard(title: L("Large Files", "File besar"),
                         value: L(large.count == 1 ? "1 file" : "\(large.count) files", "\(large.count) file"),
                         detail: L("\(Fmt.size(large.size)) · view list ›", "\(Fmt.size(large.size)) · lihat daftar ›")) { model.tool = .large }
            } else {
                StatCard(title: L("Large Files", "File besar"), value: "—",
                         detail: L("Scan the disk first", "Pindai disk dulu"))
            }
        }
    }

    // MARK: map

    private var map: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                GeometryReader { g in
                    let rects = Treemap.layout(blocks.map { Double($0.size) }, in: CGRect(origin: .zero, size: g.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(blocks.enumerated()), id: \.element.id) { i, b in
                            let r = rects[i].insetBy(dx: 3, dy: 3)
                            if r.width > 2 && r.height > 2 {
                                topBlock(b, size: r.size)
                                    .frame(width: r.width, height: r.height)
                                    .offset(x: r.minX, y: r.minY)
                            }
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                }
                .padding(17)
                .id(current)
                .transition(.opacity)
                Divider()
                sidePanel.frame(width: 290)
            }
            .animation(.easeOut(duration: 0.18), value: current)
            collectBar
        }
    }

    private func topBlock(_ b: MapBlock, size: CGSize) -> some View {
        let showHeader = size.width >= 56 && size.height >= 30
        let headerH: CGFloat = showHeader ? 28 : 0
        let inner = CGRect(x: 6, y: headerH, width: size.width - 12, height: size.height - headerH - 6)
        let kids = inner.width > 24 && inner.height > 20 ? b.children : []
        let rects = Treemap.layout(kids.map { Double($0.size) }, in: inner)
        let text = b.light ? Color.black.opacity(0.72) : Color.white

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7)
                .fill(b.color)
                .brightness(hovered == b.id ? 0.04 : 0)
            if showHeader {
                HStack(alignment: .firstTextBaseline) {
                    Text(b.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if size.width > 130 { Text(Fmt.size(b.size)).font(.system(size: 11)).opacity(0.85).monospacedDigit() }
                }
                .foregroundStyle(text)
                .padding(.horizontal, 9).frame(height: headerH)
                .frame(width: size.width, alignment: .leading)
                if kids.isEmpty && size.width <= 130 && size.height > 46 {
                    Text(Fmt.size(b.size)).font(.system(size: 11)).foregroundStyle(text.opacity(0.85))
                        .padding(.horizontal, 9).offset(y: headerH - 6)
                }
            }
            ForEach(Array(kids.enumerated()), id: \.element.id) { i, k in
                let r = rects[i].insetBy(dx: 1.5, dy: 1.5)
                if r.width > 2 && r.height > 2 {
                    childBlock(k, size: r.size)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }
            markOverlay(b, cornerRadius: 7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .modifier(BlockActions(block: b, marked: isMarked(b), markable: markable(b),
                               open: { focus = $0 }, toggle: toggle, reveal: { model.reveal([$0]) }))
        .onHover { hovered = $0 ? b.id : (hovered == b.id ? nil : hovered) }
        .help(tooltip(b))
    }

    private func childBlock(_ b: MapBlock, size: CGSize) -> some View {
        let text = b.light ? Color.black.opacity(0.72) : Color.white
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 4).fill(b.color)
            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(b.shade + (hovered == b.id ? 0.1 : 0)))
            if size.width >= 50 && size.height >= 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(b.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(Fmt.size(b.size)).font(.system(size: 10.5)).opacity(0.85).monospacedDigit()
                }
                .foregroundStyle(text)
                .padding(.horizontal, 8).padding(.bottom, 6)
            }
            markOverlay(b, cornerRadius: 4)
        }
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .modifier(BlockActions(block: b, marked: isMarked(b), markable: markable(b),
                               open: { focus = $0 }, toggle: toggle, reveal: { model.reveal([$0]) }))
        .onHover { hovered = $0 ? b.id : (hovered == b.id ? nil : hovered) }
        .help(tooltip(b))
    }

    @ViewBuilder
    private func markOverlay(_ b: MapBlock, cornerRadius: CGFloat) -> some View {
        if isMarked(b) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: cornerRadius).fill(Color.black.opacity(0.18))
                RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.white, lineWidth: 2.5)
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentTeal)
                    .font(.system(size: 14))
                    .padding(5)
            }
            .allowsHitTesting(false)
        }
    }

    private func tooltip(_ b: MapBlock) -> String {
        if let p = b.path { return "\((p as NSString).abbreviatingWithTildeInPath)\n\(Fmt.size(b.size))" }
        if let c = Category.allCases.first(where: { "cat:" + $0.rawValue == b.id }) {
            return "\(c.title) · \(Fmt.size(b.size))\n\(c.help)"
        }
        return "\(b.name) · \(Fmt.size(b.size))\n" + L("Small files and folders grouped together", "File dan folder kecil yang digabung")
    }

    // MARK: side panel

    private var sidePanel: some View {
        let maxSize = max(1, blocks.map(\.size).max() ?? 1)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(panelKind).font(.caption).foregroundStyle(.secondary)
                Text(panelTitle).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(panelPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.size(panelSize)).font(.system(size: 24, weight: .medium)).monospacedDigit()
                    Text(panelCount)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .padding(20)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(blocks) { b in
                        sideRow(b, frac: Double(b.size) / Double(maxSize))
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func sideRow(_ b: MapBlock, frac: Double) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { isMarked(b) }, set: { _ in if let p = b.path { toggle(p) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!markable(b))
                .help(markable(b) ? L("Collect", "Kumpulkan") : L("Can't be deleted from here", "Tidak bisa dihapus dari sini"))
            RoundedRectangle(cornerRadius: 2.5)
                .fill(b.color)
                .frame(width: 10, height: 10)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    if let t = b.target { focus = t }
                } label: {
                    Text(b.name).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(b.target == nil ? "" : L("Open", "Buka"))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(b.light ? Color.gray : b.color)
                            .frame(width: max(2, g.size.width * frac))
                    }
                }
                .frame(height: 3)
            }
            Text(Fmt.size(b.size)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20).padding(.vertical, 7)
        .contextMenu {
            if let t = b.target { Button(L("Open", "Buka")) { focus = t } }
            if let p = b.path { Button(L("Show in Finder", "Tampilkan di Finder")) { model.reveal([p]) } }
        }
    }

    private var panelKind: String {
        switch current {
        case .overview: L("Disk", "Disk")
        case .category: L("Category", "Kategori")
        case .node: L("Folder", "Folder")
        }
    }

    private var panelCount: String {
        let n = blocks.count
        if current == .overview { return L(n == 1 ? "1 category" : "\(n) categories", "\(n) kategori") }
        return L(n == 1 ? "1 item" : "\(n) items", "\(n) item")
    }

    private var panelTitle: String {
        switch current {
        case .overview: model.volumeName
        case .category(let k): Category(rawValue: k)?.title ?? k
        case .node(let p): model.node(at: p)?.name ?? (p as NSString).lastPathComponent
        }
    }

    private var panelPath: String {
        switch current {
        case .overview: "/"
        case .category(let k): Category(rawValue: k)?.help ?? ""
        case .node(let p): (p as NSString).abbreviatingWithTildeInPath
        }
    }

    private var panelSize: Int64 {
        switch current {
        case .overview: model.volumeUsed
        case .category, .node: blocks.reduce(0) { $0 + $1.size }
        }
    }

    // MARK: collecting

    private func isMarked(_ b: MapBlock) -> Bool { b.path.map(marks.contains) ?? false }

    private func markable(_ b: MapBlock) -> Bool {
        guard let p = b.path else { return false }
        return !DeepCleaner.isProtected(p)
    }

    private func toggle(_ path: String) {
        guard !DeepCleaner.isProtected(path) else { return }
        var m = marks
        if m.contains(path) {
            m.remove(path)
        } else {
            // a folder includes everything inside it
            m = m.filter { !$0.hasPrefix(path + "/") }
            m.insert(path)
        }
        model.marks[.home] = m
    }

    /// Marked items, leaving out anything inside a marked folder.
    private var collected: [Item] {
        let m = marks
        return m.filter { p in
            var up = (p as NSString).deletingLastPathComponent
            while up.count > 1 {
                if m.contains(up) { return false }
                up = (up as NSString).deletingLastPathComponent
            }
            return true
        }
        .compactMap { p in
            if let n = model.node(at: p) { return Item(n) }
            let parent = (p as NSString).deletingLastPathComponent
            return filesByParent[parent]?.first { $0.path == p }.map(Item.init)
        }
        .sorted { $0.size > $1.size }
    }

    private var collectBar: some View {
        let items = collected
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let totalText = total == 0 ? "0 MB" : Fmt.size(total)
        let more = items.count - 3
        return HStack(spacing: 12) {
            Text("\(items.count)")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(items.isEmpty ? Color.secondary : Color.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(items.isEmpty ? Color.secondary.opacity(0.15) : Color.accentTeal))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("\(totalText) collected", "\(totalText) dikumpulkan")).font(.system(size: 13, weight: .medium)).monospacedDigit()
                Text(items.isEmpty
                     ? L("Click files in the chart or check items in the list to collect them. Double-click to open a folder.",
                         "Klik file di grafik atau centang item di daftar untuk mengumpulkannya. Klik dua kali untuk membuka folder.")
                     : items.prefix(3).map(\.name).joined(separator: ", ") + (more > 0 ? L(" and \(more) more", " dan \(more) lainnya") : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Button(L("Show in Finder", "Tampilkan di Finder")) { model.reveal(items.map(\.path)) }
                .disabled(items.isEmpty)
            Button(L("Clear", "Kosongkan")) { model.marks[.home] = [] }
                .disabled(items.isEmpty)
            Button {
                model.requestDelete(items, from: .home)
            } label: {
                Label(L("Move to Trash…", "Pindahkan ke Sampah…"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(items.isEmpty)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Pieces

/// Click to collect, double-click to open, plus a context menu.
private struct BlockActions: ViewModifier {
    let block: MapBlock
    let marked: Bool
    let markable: Bool
    let open: (MapFocus) -> Void
    let toggle: (String) -> Void
    let reveal: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) { if let t = block.target { open(t) } }
            .onTapGesture { if markable, let p = block.path { toggle(p) } }
            .contextMenu {
                if let t = block.target { Button(L("Open", "Buka")) { open(t) } }
                if markable, let p = block.path {
                    Button(marked ? L("Uncollect", "Batal Kumpulkan") : L("Collect", "Kumpulkan")) { toggle(p) }
                }
                if let p = block.path {
                    Divider()
                    Button(L("Show in Finder", "Tampilkan di Finder")) { reveal(p) }
                }
            }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    var highlight = false
    var action: (() -> Void)? = nil

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11.5, weight: highlight ? .medium : .regular))
                .foregroundStyle(highlight ? Color.accentTeal : .secondary)
            Text(value).font(.system(size: 21, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.primary)
            Text(detail).font(.system(size: 11.5))
                .foregroundStyle(highlight && action != nil ? Color.accentTeal : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(highlight ? Color.accentTeal.opacity(0.11) : Color.primary.opacity(0.045))
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}
