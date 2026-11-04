import Foundation

/// A formula or cask installed through Homebrew.
struct BrewPackage: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case formula, cask }

    let kind: Kind
    /// formula name or cask token, what `brew` takes as an argument
    let name: String
    /// human name (casks have one, formulae use their name)
    let title: String
    let desc: String
    let homepage: String
    /// installed version (the linked one for formulae)
    let version: String
    let latest: String
    let outdated: Bool
    let pinned: Bool
    /// formula installed by the user, not only as a dependency (always true for casks)
    let onRequest: Bool
    /// installed formulae this package needs directly
    let deps: [String]
    /// installed packages that need this formula
    var usedBy: [String] = []
    /// Cellar/Caskroom folder plus any app bundles the cask put in Applications
    var size: Int64 = 0
    /// older formula versions still in the Cellar, freed by `brew cleanup`
    var oldVersionsSize: Int64 = 0
    /// where it lives on disk: keg folder, Caskroom folder, installed apps
    var paths: [String] = []

    var id: String { "\(kind.rawValue):\(name)" }
    var kindLabel: String { kind == .cask ? "Cask" : "Formula" }
    /// .app installed by a cask, for its icon
    var appPath: String? { paths.first { $0.hasSuffix(".app") } }
    /// installed only to satisfy another package that is gone now
    var isUnusedDependency: Bool { kind == .formula && !onRequest && usedBy.isEmpty }
}

enum Homebrew {
    /// `brew` executable, nil when Homebrew isn't installed
    static let executable: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// /opt/homebrew on Apple Silicon, /usr/local on Intel
    static var prefix: String? {
        executable.map { (($0 as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent }
    }

    struct Output: Sendable {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
        /// what to show when the command failed: the error lines, or everything
        var message: String {
            let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return e.isEmpty ? out.trimmingCharacters(in: .whitespacesAndNewlines) : e
        }
    }

    /// Runs `brew` with the given arguments and waits for it to finish.
    static func run(_ args: [String]) -> Output {
        guard let brew = executable else { return Output(status: -1, out: "", err: "Homebrew not found") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brew)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["HOMEBREW_NO_EMOJI"] = "1"
        // apps started from Finder get a bare PATH; brew and its tools need their own bin
        if let p = prefix { env["PATH"] = "\(p)/bin:\(p)/sbin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") }
        proc.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch {
            return Output(status: -1, out: "", err: error.localizedDescription)
        }
        // drain both pipes at once so a full stderr buffer can't stall the process
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        proc.waitUntilExit()
        return Output(status: proc.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    /// Everything Homebrew has installed, with sizes measured on disk.
    /// Throws a message when `brew` fails or its output can't be read.
    static func installed() throws -> [BrewPackage] {
        let r = run(["info", "--json=v2", "--installed"])
        guard r.ok else { throw BrewError(message: r.message) }
        guard let json = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any] else {
            throw BrewError(message: L("Couldn't read Homebrew's output.", "Output Homebrew tidak bisa dibaca."))
        }
        let formulae = (json["formulae"] as? [[String: Any]] ?? []).compactMap(formula)
        let casks = (json["casks"] as? [[String: Any]] ?? []).compactMap(cask)
        var all = formulae + casks

        // reverse dependencies
        var users: [String: [String]] = [:]
        for p in all { for d in p.deps { users[d, default: []].append(p.name) } }
        for i in all.indices where all[i].kind == .formula {
            all[i].usedBy = (users[all[i].name] ?? []).sorted()
        }

        // sizes, in parallel: a few hundred folders of mostly small files
        let cellar = (prefix ?? "/opt/homebrew") + "/Cellar"
        let caskroom = (prefix ?? "/opt/homebrew") + "/Caskroom"
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: all.count) { i in
            var p = all[i]
            if p.kind == .formula {
                let keg = cellar + "/" + p.name
                var total: Int64 = 0, old: Int64 = 0
                for v in FS.list(keg) ?? [] {
                    let s = FS.usage(keg + "/" + v).size
                    total += s
                    if v != p.version { old += s }
                }
                p.size = total
                p.oldVersionsSize = old
                p.paths = [keg]
            } else {
                let room = caskroom + "/" + p.name
                p.size = FS.usage(room).size + p.paths.reduce(0) { $0 + FS.usage($1).size }
                p.paths = p.paths + [room]
            }
            lock.lock(); all[i] = p; lock.unlock()
        }
        return all
    }

    private static func formula(_ f: [String: Any]) -> BrewPackage? {
        guard let name = f["name"] as? String else { return nil }
        let installed = f["installed"] as? [[String: Any]] ?? []
        let linked = f["linked_keg"] as? String
        // the linked keg is the one in use; without one, the newest install
        let current = installed.first { ($0["version"] as? String) == linked } ?? installed.last
        let deps = (current?["runtime_dependencies"] as? [[String: Any]] ?? [])
            .filter { ($0["declared_directly"] as? Bool) ?? true }
            .compactMap { ($0["full_name"] as? String).map { ($0 as NSString).lastPathComponent } }
        let versions = f["versions"] as? [String: Any]
        return BrewPackage(
            kind: .formula, name: name, title: name,
            desc: f["desc"] as? String ?? "",
            homepage: f["homepage"] as? String ?? "",
            version: linked ?? current?["version"] as? String ?? "",
            latest: versions?["stable"] as? String ?? "",
            outdated: f["outdated"] as? Bool ?? false,
            pinned: f["pinned"] as? Bool ?? false,
            onRequest: installed.contains { ($0["installed_on_request"] as? Bool) == true },
            deps: deps)
    }

    private static func cask(_ c: [String: Any]) -> BrewPackage? {
        guard let token = c["token"] as? String else { return nil }
        let deps = ((c["depends_on"] as? [String: Any])?["formula"] as? [String] ?? [])
            .map { ($0 as NSString).lastPathComponent }
        let installedVersion: String = (c["installed"] as? String) ?? ""
        return BrewPackage(
            kind: .cask, name: token,
            title: (c["name"] as? [String])?.first ?? token,
            desc: c["desc"] as? String ?? "",
            homepage: c["homepage"] as? String ?? "",
            version: installedVersion,
            latest: c["version"] as? String ?? "",
            outdated: c["outdated"] as? Bool ?? false,
            pinned: false, onRequest: true, deps: deps,
            paths: appBundles(c["artifacts"] as? [Any] ?? []))
    }

    /// App bundles a cask installed, from its `app` artifacts. Only those that exist.
    private static func appBundles(_ artifacts: [Any]) -> [String] {
        var out: [String] = []
        for case let a as [String: Any] in artifacts {
            guard let app = a["app"] as? [Any] else { continue }
            // ["Foo.app"] or ["Foo.app", {"target": "Bar.app"}]
            var name = app.first as? String
            for case let opts as [String: Any] in app { if let t = opts["target"] as? String { name = t } }
            guard let name else { continue }
            let target = (name as NSString).lastPathComponent
            let candidates = name.hasPrefix("/") ? [name]
                : ["/Applications/" + name, NSHomeDirectory() + "/Applications/" + target]
            if let hit = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) { out.append(hit) }
        }
        return out
    }

    /// `brew uninstall` for the given packages. `zap` also removes a cask's app data.
    static func uninstall(_ pkgs: [BrewPackage], zap: Bool) -> Output {
        let formulae = pkgs.filter { $0.kind == .formula }.map(\.name)
        let casks = pkgs.filter { $0.kind == .cask }.map(\.name)
        var outs: [Output] = []
        if !formulae.isEmpty { outs.append(run(["uninstall", "--formula"] + formulae)) }
        if !casks.isEmpty { outs.append(run(["uninstall", "--cask"] + (zap ? ["--zap"] : []) + casks)) }
        let failed = outs.filter { !$0.ok }
        return Output(status: failed.first?.status ?? 0,
                      out: outs.map(\.out).joined(separator: "\n"),
                      err: failed.map(\.message).joined(separator: "\n\n"))
    }

    /// `brew cleanup`: removes old versions and the download cache.
    /// Returns the "freed approximately X" amount when brew reports one.
    static func cleanup() -> (Output, freed: String?) {
        let r = run(["cleanup"])
        let freed = (r.out + "\n" + r.err).split(separator: "\n")
            .first { $0.contains("freed approximately") }
            .flatMap { line -> String? in
                guard let range = line.range(of: "approximately ") else { return nil }
                return line[range.upperBound...].split(separator: " ").first.map(String.init)
            }
        return (r, freed)
    }
}

struct BrewError: Error { let message: String }
