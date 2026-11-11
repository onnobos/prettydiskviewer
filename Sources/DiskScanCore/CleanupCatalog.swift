import Foundation

public enum CleanupSafety: String, Sendable {
    case safe       // 🟢 Safe to remove, regenerates automatically
    case review     // 🟡 Safe but review first (e.g. downloads, inactive projects)
    case careful    // 🔴 Important user data, reveal in Finder only
    case info       // ℹ️ Informational (e.g. Trash size)
    
    public var badge: String {
        switch self {
        case .safe: return "🟢 Safe"
        case .review: return "🟡 Review"
        case .careful: return "🔴 Careful"
        case .info: return "ℹ️ Info"
        }
    }
}

public enum CleanupActionKind: String, Sendable {
    case trash
    case command
    case reveal
    case info
}

public struct CleanupItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let explanation: String
    public let path: String
    public let size: Int64
    public let frees: Int64
    public let safety: CleanupSafety
    public let actionKind: CleanupActionKind
    public let command: String?
    
    public init(id: String,
                title: String,
                explanation: String,
                path: String,
                size: Int64,
                frees: Int64,
                safety: CleanupSafety,
                actionKind: CleanupActionKind,
                command: String? = nil) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.path = path
        self.size = size
        self.frees = frees > 0 ? frees : size
        self.safety = safety
        self.actionKind = actionKind
        self.command = command
    }
}

public final class CleanupCatalog: Sendable {
    public static let shared = CleanupCatalog()
    
    public init() {}
    
    /// Scans known locations or matches within a pre-scanned tree
    public func findCleanupItems(tree: ScanTree? = nil) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let home = NSHomeDirectory()
        let fm = FileManager.default
        
        func diskUsage(for path: String) -> (size: Int64, frees: Int64)? {
            // If tree covers this path, find it in tree
            if let tree = tree, path.hasPrefix(tree.rootPath) {
                // Find node in tree
                if let node = findNode(in: tree, for: path) {
                    return (node.size, node.frees)
                }
            }
            // Quick stat/directory walk if not in tree
            guard fm.fileExists(atPath: path) else { return nil }
            let scanner = DiskScanner(options: ScanOptions(crossMounts: false, maxParallelDepth: 1, threads: 4))
            let (root, _) = scanner.scan(path: path)
            return (root.size, root.frees)
        }
        
        // 1. Xcode DerivedData
        let derivedData = "\(home)/Library/Developer/Xcode/DerivedData"
        if let usage = diskUsage(for: derivedData), usage.size > 1_000_000 {
            items.append(CleanupItem(
                id: "xcode.deriveddata",
                title: "Xcode DerivedData",
                explanation: "Build products and index files. Rebuilt automatically on next build.",
                path: derivedData,
                size: usage.size,
                frees: usage.frees,
                safety: .safe,
                actionKind: .trash
            ))
        }
        
        // 2. Xcode iOS DeviceSupport
        let deviceSupport = "\(home)/Library/Developer/Xcode/iOS DeviceSupport"
        if let usage = diskUsage(for: deviceSupport), usage.size > 10_000_000 {
            items.append(CleanupItem(
                id: "xcode.devicesupport",
                title: "Xcode iOS DeviceSupport",
                explanation: "Symbols from previously connected physical iOS devices.",
                path: deviceSupport,
                size: usage.size,
                frees: usage.frees,
                safety: .safe,
                actionKind: .trash
            ))
        }
        
        // 3. Xcode Archives (older than 90 days)
        let archivesPath = "\(home)/Library/Developer/Xcode/Archives"
        if let usage = diskUsage(for: archivesPath), usage.size > 10_000_000 {
            items.append(CleanupItem(
                id: "xcode.archives",
                title: "Xcode Archives",
                explanation: "Past app build archives for distribution.",
                path: archivesPath,
                size: usage.size,
                frees: usage.frees,
                safety: .review,
                actionKind: .trash
            ))
        }
        
        // 4. App Caches (~/Library/Caches/*)
        let cachesDir = "\(home)/Library/Caches"
        if fm.fileExists(atPath: cachesDir), let subdirs = try? fm.contentsOfDirectory(atPath: cachesDir) {
            for sub in subdirs {
                let p = "\(cachesDir)/\(sub)"
                if let usage = diskUsage(for: p), usage.size > 200_000_000 { // > 200 MB
                    items.append(CleanupItem(
                        id: "cache.\(sub)",
                        title: "\(sub) Cache",
                        explanation: "Temporary application cache files.",
                        path: p,
                        size: usage.size,
                        frees: usage.frees,
                        safety: .safe,
                        actionKind: .trash
                    ))
                }
            }
        }
        
        // 5. Developer package caches
        let devCaches: [(id: String, title: String, path: String, cmd: String?)] = [
            ("dev.npm", "npm Cache", "\(home)/.npm", "npm cache clean --force"),
            ("dev.yarn", "Yarn Cache", "\(home)/Library/Caches/Yarn", "yarn cache clean"),
            ("dev.pnpm", "pnpm Store", "\(home)/Library/pnpm/store", "pnpm store prune"),
            ("dev.cocoapods", "CocoaPods Cache", "\(home)/Library/Caches/CocoaPods", "pod cache clean --all"),
            ("dev.gradle", "Gradle Caches", "\(home)/.gradle/caches", nil),
            ("dev.pip", "pip Cache", "\(home)/Library/Caches/pip", "pip cache purge"),
            ("dev.homebrew", "Homebrew Cache", "\(home)/Library/Caches/Homebrew", "brew cleanup")
        ]
        
        for dc in devCaches {
            if let usage = diskUsage(for: dc.path), usage.size > 10_000_000 {
                items.append(CleanupItem(
                    id: dc.id,
                    title: dc.title,
                    explanation: "Downloaded packages and build artifacts cache.",
                    path: dc.path,
                    size: usage.size,
                    frees: usage.frees,
                    safety: .safe,
                    actionKind: dc.cmd != nil ? .command : .trash,
                    command: dc.cmd
                ))
            }
        }
        
        // 6. Docker disk image
        let dockerRaw = "\(home)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        if fm.fileExists(atPath: dockerRaw) {
            var st = stat()
            if stat(dockerRaw, &st) == 0 {
                let sz = Int64(st.st_blocks) * 512
                if sz > 1_000_000_000 { // > 1 GB
                    items.append(CleanupItem(
                        id: "docker.raw",
                        title: "Docker Virtual Disk",
                        explanation: "Docker VM raw disk image. Use Docker command to safely prune unused containers and images (never delete file directly).",
                        path: dockerRaw,
                        size: sz,
                        frees: sz,
                        safety: .review,
                        actionKind: .command,
                        command: "docker system prune -a --volumes"
                    ))
                }
            }
        }
        
        // 7. Old Downloads (.dmg, .pkg, .iso, .zip > 30 days)
        let downloads = "\(home)/Downloads"
        if fm.fileExists(atPath: downloads), let contents = try? fm.contentsOfDirectory(atPath: downloads) {
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            let installerExts: Set<String> = ["dmg", "pkg", "iso", "zip"]
            var totalDlSize: Int64 = 0
            var count = 0
            for file in contents {
                let ext = (file as NSString).pathExtension.lowercased()
                if installerExts.contains(ext) {
                    let full = "\(downloads)/\(file)"
                    if let attrs = try? fm.attributesOfItem(atPath: full),
                       let modDate = attrs[.modificationDate] as? Date,
                       modDate < cutoff,
                       let sz = attrs[.size] as? Int64 {
                        totalDlSize += sz
                        count += 1
                    }
                }
            }
            if totalDlSize > 50_000_000 {
                items.append(CleanupItem(
                    id: "downloads.old",
                    title: "Old Downloaded Installers (\(count) files)",
                    explanation: ".dmg, .pkg, .iso files in ~/Downloads older than 30 days.",
                    path: downloads,
                    size: totalDlSize,
                    frees: totalDlSize,
                    safety: .review,
                    actionKind: .reveal
                ))
            }
        }
        
        // 8. iOS MobileSync backups
        let mobileSync = "\(home)/Library/Application Support/MobileSync/Backup"
        if let usage = diskUsage(for: mobileSync), usage.size > 100_000_000 {
            items.append(CleanupItem(
                id: "ios.backups",
                title: "iOS Device Backups",
                explanation: "Local iPhone / iPad backups. Manage in Finder > Device Settings.",
                path: mobileSync,
                size: usage.size,
                frees: usage.frees,
                safety: .careful,
                actionKind: .reveal
            ))
        }
        
        // 9. Trash itself
        let trashPath = "\(home)/.Trash"
        if let usage = diskUsage(for: trashPath), usage.size > 10_000_000 {
            items.append(CleanupItem(
                id: "macos.trash",
                title: "macOS Trash",
                explanation: "Files already in Trash. Empty Trash via Finder or Dock to permanently reclaim this space.",
                path: trashPath,
                size: usage.size,
                frees: usage.frees,
                safety: .info,
                actionKind: .info
            ))
        }
        
        // 10. APFS Time Machine Local Snapshots
        let snapshots = VolumeManager.listLocalSnapshots(mountPoint: "/")
        for snap in snapshots {
            let parts = snap.components(separatedBy: ".")
            let dateStr = parts.count >= 4 ? parts[3] : snap
            items.append(CleanupItem(
                id: "snapshot.\(snap)",
                title: "📸 APFS Time Machine Snapshot (\(dateStr))",
                explanation: "Local APFS snapshot locking modified/deleted disk blocks. Pruning reclaims physical disk space.",
                path: snap,
                size: 0,
                frees: 0,
                safety: .review,
                actionKind: .command,
                command: "tmutil deletelocalsnapshots \(dateStr)"
            ))
        }
        
        // Sort items by size descending
        return items.sorted { $0.size > $1.size }
    }
    
    private func findNode(in tree: ScanTree, for targetPath: String) -> NodeRef? {
        let root = tree.root
        if root.path == targetPath { return root }
        
        // Split target relative to root
        var rel = targetPath
        if rel.hasPrefix(root.path) {
            rel = String(rel.dropFirst(root.path.count))
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        }
        let segments = rel.split(separator: "/").map(String.init)
        
        var curr = root
        for segment in segments {
            if let next = curr.children.first(where: { $0.name == segment }) {
                curr = next
            } else {
                return nil
            }
        }
        return curr
    }
}
