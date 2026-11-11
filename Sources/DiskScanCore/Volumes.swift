import Foundation

public struct VolumeDiskDetails: Sendable {
    public let name: String
    public let mountPoint: String
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let freeBytes: Int64
    public let purgeableBytes: Int64
    public let localSnapshots: [String]
    
    public init(name: String,
                mountPoint: String,
                totalBytes: Int64,
                usedBytes: Int64,
                freeBytes: Int64,
                purgeableBytes: Int64,
                localSnapshots: [String]) {
        self.name = name
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.purgeableBytes = purgeableBytes
        self.localSnapshots = localSnapshots
    }
}

public struct VolumeInfo: Sendable, Identifiable {
    public var id: String { mountPoint }
    public let name: String
    public let mountPoint: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let usedBytes: Int64
    public let purgeableBytes: Int64
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isReadOnly: Bool
    public let fileSystemType: String
    
    public init(name: String,
                mountPoint: String,
                totalBytes: Int64,
                freeBytes: Int64,
                usedBytes: Int64,
                purgeableBytes: Int64 = 0,
                isInternal: Bool,
                isRemovable: Bool,
                isReadOnly: Bool,
                fileSystemType: String) {
        self.name = name
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
        self.purgeableBytes = purgeableBytes
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isReadOnly = isReadOnly
        self.fileSystemType = fileSystemType
    }
}

public enum VolumeManager {
    /// Returns all accessible mounted volumes on the system
    public static func listVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsReadOnlyKey,
            .volumeTypeNameKey
        ]
        
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }
        
        var list: [VolumeInfo] = []
        for url in urls {
            guard let vals = try? url.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            let name = vals.volumeName ?? url.lastPathComponent
            let total = Int64(vals.volumeTotalCapacity ?? 0)
            let freeImportant = vals.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
            let freePure = vals.volumeAvailableCapacity.map { Int64($0) }
            let free = freeImportant ?? freePure ?? 0
            let purgeable = max(0, (freeImportant ?? free) - (freePure ?? free))
            let used = max(0, total - free)
            let isInternal = vals.volumeIsInternal ?? true
            let isRemovable = vals.volumeIsRemovable ?? false
            let isReadOnly = vals.volumeIsReadOnly ?? false
            let fsType = vals.volumeTypeName ?? "APFS"
            
            let info = VolumeInfo(
                name: name,
                mountPoint: url.path,
                totalBytes: total,
                freeBytes: free,
                usedBytes: used,
                purgeableBytes: purgeable,
                isInternal: isInternal,
                isRemovable: isRemovable,
                isReadOnly: isReadOnly,
                fileSystemType: fsType
            )
            list.append(info)
        }
        
        // Sort: internal main disk first, then external disks alphabetically
        return list.sorted {
            if $0.mountPoint == "/" { return true }
            if $1.mountPoint == "/" { return false }
            if $0.isInternal != $1.isInternal {
                return $0.isInternal && !$1.isInternal
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    
    /// Queries active APFS local Time Machine snapshots
    public static func listLocalSnapshots(mountPoint: String = "/") -> [String] {
        let p = Process()
        p.launchPath = "/usr/bin/tmutil"
        p.arguments = ["listlocalsnapshots", mountPoint]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                var snapshots: [String] = []
                for line in output.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("com.apple.TimeMachine.") {
                        snapshots.append(trimmed)
                    }
                }
                return snapshots
            }
        } catch {}
        return []
    }
    
    /// Returns total active files/inodes on the volume containing the given path
    public static func volumeTotalFiles(forPath path: String) -> Int64? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let total = Int64(s.f_files)
        let free = Int64(s.f_ffree)
        let used = total - free
        return used > 0 ? used : nil
    }
    
    /// Returns detailed disk usage matching Finder's Get Info numbers
    public static func volumeDetails(forPath path: String) -> VolumeDiskDetails? {
        let volumes = listVolumes()
        let matching = volumes.filter { path == $0.mountPoint || path.hasPrefix($0.mountPoint == "/" ? "/" : $0.mountPoint + "/") }
            .sorted { $0.mountPoint.count > $1.mountPoint.count }
            .first
        
        guard let v = matching, v.totalBytes > 0 else { return nil }
        let snapshots = (v.mountPoint == "/" || path == "/") ? listLocalSnapshots(mountPoint: "/") : []
        
        return VolumeDiskDetails(
            name: v.name,
            mountPoint: v.mountPoint,
            totalBytes: v.totalBytes,
            usedBytes: v.usedBytes,
            freeBytes: v.freeBytes,
            purgeableBytes: v.purgeableBytes,
            localSnapshots: snapshots
        )
    }
    
    /// Returns total capacity and currently used bytes on the volume containing the path
    public static func volumeTotalAndUsed(forPath path: String) -> (total: Int64, used: Int64)? {
        if let d = volumeDetails(forPath: path) {
            return (d.totalBytes, d.usedBytes)
        }
        return nil
    }
}
