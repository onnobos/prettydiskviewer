import Foundation

public enum ItemKind: String, Sendable, Codable {
    case file
    case directory
    case symlink
    case other
    
    public var icon: String {
        switch self {
        case .file: return "📄"
        case .directory: return "📁"
        case .symlink: return "🔗"
        case .other: return "📦"
        }
    }
}

public enum SortMode: Sendable {
    case sizeDescending
    case nameAscending
    case filesCountDescending
}

public final class FileNode: @unchecked Sendable {
    public let name: String
    public var allocatedSize: Int64
    public var apparentSize: Int64
    public var frees: Int64
    public var fileCount: Int64
    public var dirCount: Int64
    public let kind: ItemKind
    public let isFirmlink: Bool
    public let isMountPoint: Bool
    
    public var children: [FileNode] = []
    public weak var parent: FileNode?
    
    public init(name: String,
                allocatedSize: Int64 = 0,
                apparentSize: Int64 = 0,
                frees: Int64 = 0,
                fileCount: Int64 = 0,
                dirCount: Int64 = 0,
                kind: ItemKind,
                isFirmlink: Bool = false,
                isMountPoint: Bool = false) {
        self.name = name
        self.allocatedSize = allocatedSize
        self.apparentSize = apparentSize
        self.frees = frees > 0 ? frees : allocatedSize
        self.fileCount = fileCount
        self.dirCount = dirCount
        self.kind = kind
        self.isFirmlink = isFirmlink
        self.isMountPoint = isMountPoint
    }
    
    /// Computes full absolute path by traversing parent chain
    public var path: String {
        guard let p = parent else {
            return name.isEmpty ? "/" : name
        }
        let parentPath = p.path
        if parentPath == "/" {
            return "/" + name
        }
        return parentPath + "/" + name
    }
    
    public func addChild(_ child: FileNode) {
        child.parent = self
        children.append(child)
    }
    
    public func removeChild(named name: String) -> FileNode? {
        if let idx = children.firstIndex(where: { $0.name == name }) {
            let removed = children.remove(at: idx)
            removed.parent = nil
            // Subtract removed node's size and count from ancestors
            var curr: FileNode? = self
            while let c = curr {
                c.allocatedSize -= removed.allocatedSize
                c.apparentSize -= removed.apparentSize
                c.frees -= removed.frees
                c.fileCount -= removed.fileCount
                c.dirCount -= (removed.kind == .directory ? (removed.dirCount + 1) : 0)
                curr = c.parent
            }
            return removed
        }
        return nil
    }
    
    public func sortedChildren(by mode: SortMode) -> [FileNode] {
        switch mode {
        case .sizeDescending:
            return children.sorted {
                if $0.allocatedSize != $1.allocatedSize {
                    return $0.allocatedSize > $1.allocatedSize
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .nameAscending:
            return children.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .filesCountDescending:
            return children.sorted {
                if $0.fileCount != $1.fileCount {
                    return $0.fileCount > $1.fileCount
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
    
    public var cleanupHint: CleanupHint? {
        FriendlyHints.hintFor(name: name, path: path)
    }
}

public struct BigFileEntry: Sendable, Equatable {
    public let path: String
    public let name: String
    public let allocatedSize: Int64
    public let apparentSize: Int64
    public let frees: Int64
    public let mtime: Date
    
    public init(path: String,
                name: String,
                allocatedSize: Int64,
                apparentSize: Int64,
                frees: Int64 = 0,
                mtime: Date = Date()) {
        self.path = path
        self.name = name
        self.allocatedSize = allocatedSize
        self.apparentSize = apparentSize
        self.frees = frees > 0 ? frees : allocatedSize
        self.mtime = mtime
    }
}

public struct ScanStats: Sendable {
    public var rootPath: String = ""
    public var totalFilesScanned: Int64 = 0
    public var totalDirsScanned: Int64 = 0
    public var dirsDiscovered: Int64 = 0
    public var totalAllocatedBytes: Int64 = 0
    public var totalApparentBytes: Int64 = 0
    public var totalFreesBytes: Int64 = 0
    public var unreadablePaths: [String] = []
    public var skippedMountPoints: [String] = []
    public var elapsedSeconds: Double = 0.0
    public var usedFallback: Bool = false
    public var isCancelled: Bool = false
    public var volumeTotalFiles: Int64? = nil
    public var topFiles: [BigFileEntry] = []
    
    public init() {}
}
