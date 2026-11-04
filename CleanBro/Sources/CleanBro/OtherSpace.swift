import Foundation

/// What the disk scan can't see but still takes space on the startup disk:
/// the other APFS volumes of its container, local snapshots, and folders the
/// scan left out.
struct OtherSpaceInfo {
    struct Volume { let name: String; let role: String; let size: Int64 }
    struct Folder { let path: String; let size: Int64; let reason: SkipReason }

    /// APFS volumes next to System and Data (Preboot, Recovery, VM, Update…)
    var volumes: [Volume] = []
    /// local APFS snapshots of the startup disk (sizes aren't reported by macOS)
    var snapshots = 0
    var swapUsed: Int64 = 0
    /// skipped folders that live on this disk, with their measured size
    var folders: [Folder] = []
    /// cloud folders left out on purpose (not measured: listing them downloads files)
    var cloudFolders: [String] = []
}

enum OtherSpace {
    /// Slow (runs `diskutil`, `tmutil`, walks skipped folders): call off the main thread.
    static func measure(skipped: [(path: String, reason: SkipReason)]) -> OtherSpaceInfo {
        var info = OtherSpaceInfo()
        info.volumes = siblingVolumes()
        info.snapshots = localSnapshots()
        info.swapUsed = swapUsed()
        for s in skipped {
            switch s.reason {
            case .user, .always:
                let size = FS.usage(s.path).size
                if size > 0 { info.folders.append(.init(path: s.path, size: size, reason: s.reason)) }
            case .cloud:
                info.cloudFolders.append(s.path)
            case .network:
                break // not on this disk
            }
        }
        info.folders.sort { $0.size > $1.size }
        return info
    }

    /// Volumes in the APFS container of "/" other than System and Data, which the scan covers.
    private static func siblingVolumes() -> [OtherSpaceInfo.Volume] {
        guard let infoData = run("/usr/sbin/diskutil", ["info", "-plist", "/"]),
              let info = plist(infoData),
              let container = info["APFSContainerReference"] as? String,
              let listData = run("/usr/sbin/diskutil", ["apfs", "list", "-plist"]),
              let list = plist(listData),
              let containers = list["Containers"] as? [[String: Any]],
              let c = containers.first(where: { $0["ContainerReference"] as? String == container }),
              let vols = c["Volumes"] as? [[String: Any]]
        else { return [] }

        return vols.compactMap { v in
            let roles = v["Roles"] as? [String] ?? []
            if roles.contains("System") || roles.contains("Data") { return nil }
            let size = (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { return nil }
            return .init(name: v["Name"] as? String ?? "?", role: roles.first ?? "", size: size)
        }
        .sorted { $0.size > $1.size }
    }

    private static func localSnapshots() -> Int {
        guard let d = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]),
              let s = String(data: d, encoding: .utf8) else { return 0 }
        return s.split(separator: "\n").filter { $0.hasPrefix("com.apple.") }.count
    }

    private static func swapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int64(usage.xsu_used)
    }

    private static func plist(_ d: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any]
    }

    private static func run(_ tool: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
