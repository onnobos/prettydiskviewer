import Foundation
import AppKit

public enum ActionError: LocalizedError, Equatable {
    case itemNotFound(String)
    case cannotTrashRoot(String)
    case outsideScanRoot(String)
    case protectedSystemPath(String)
    case trashFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .itemNotFound(let p):
            return "Item not found at path: \(p)"
        case .cannotTrashRoot(let p):
            return "Refusing to trash the scan root: \(p)"
        case .outsideScanRoot(let p):
            return "Refusing to trash path outside scan root: \(p)"
        case .protectedSystemPath(let p):
            return "Refusing to trash protected system path: \(p)"
        case .trashFailed(let msg):
            return "Failed to move to Trash: \(msg)"
        }
    }
}

public struct BatchTrashResult: Sendable {
    public var succeeded: [(path: String, size: Int64)] = []
    public var failed: [(path: String, error: String)] = []
    
    public var totalFreed: Int64 {
        succeeded.reduce(0) { $0 + $1.size }
    }
    
    public init() {}
}

public enum DiskActions {
    /// Reveals the file or directory in Finder
    @discardableResult
    public static func revealInFinder(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }
    
    /// Safely moves an item to macOS Trash.
    /// Returns the approximate bytes freed.
    @discardableResult
    public static func moveToTrash(path: String, scanRoot: String) throws -> Int64 {
        let standardPath = (path as NSString).standardizingPath
        let standardRoot = (scanRoot as NSString).standardizingPath
        
        // 1. Cannot trash system root
        if standardPath == "/" || standardPath.isEmpty {
            throw ActionError.cannotTrashRoot(standardPath)
        }
        
        // 2. Protected system paths
        let protectedPrefixes = [
            "/System", "/usr", "/bin", "/sbin", "/private/var", "/Library/Apple"
        ]
        for prefix in protectedPrefixes {
            if standardPath == prefix || standardPath.hasPrefix(prefix + "/") {
                throw ActionError.protectedSystemPath(standardPath)
            }
        }
        
        // 3. Cannot trash the scan root itself
        if standardPath == standardRoot {
            throw ActionError.cannotTrashRoot(standardPath)
        }
        
        // 4. Must be inside scanRoot
        if standardRoot != "/" && !standardPath.hasPrefix(standardRoot + "/") {
            throw ActionError.outsideScanRoot(standardPath)
        }
        
        let url = URL(fileURLWithPath: standardPath)
        guard FileManager.default.fileExists(atPath: standardPath) else {
            throw ActionError.itemNotFound(standardPath)
        }
        
        // Determine size before trashing
        var st = stat()
        let size: Int64
        if lstat(standardPath, &st) == 0 {
            size = Int64(st.st_blocks) * 512
        } else {
            size = 0
        }
        
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return size
        } catch {
            throw ActionError.trashFailed(error.localizedDescription)
        }
    }
    
    /// Batch trash multiple items safely
    public static func batchMoveToTrash(paths: [String], scanRoot: String) -> BatchTrashResult {
        var result = BatchTrashResult()
        for p in paths {
            do {
                let freed = try moveToTrash(path: p, scanRoot: scanRoot)
                result.succeeded.append((path: p, size: freed))
            } catch {
                result.failed.append((path: p, error: error.localizedDescription))
            }
        }
        return result
    }
    
    /// Reports total size and file count in ~/.Trash
    public static func trashUsage() -> (size: Int64, count: Int) {
        let trashPath = ("~/.Trash" as NSString).expandingTildeInPath
        var totalSize: Int64 = 0
        var totalCount: Int = 0
        
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: trashPath) else {
            return (0, 0)
        }
        
        for item in contents {
            let full = "\(trashPath)/\(item)"
            var st = stat()
            if lstat(full, &st) == 0 {
                totalSize += Int64(st.st_blocks) * 512
                totalCount += 1
            }
        }
        return (totalSize, totalCount)
    }
}
