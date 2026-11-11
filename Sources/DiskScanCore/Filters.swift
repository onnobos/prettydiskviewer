import Foundation

public struct LargeAndOldConfig: Sendable {
    public var minSizeBytes: Int64
    public var minAgeMonths: Int
    
    public init(minSizeBytes: Int64 = 100_000_000, minAgeMonths: Int = 12) {
        self.minSizeBytes = minSizeBytes
        self.minAgeMonths = minAgeMonths
    }
}

public final class FileFilters: Sendable {
    public static func findLargeAndOldFiles(in tree: ScanTree, config: LargeAndOldConfig) -> [NodeRef] {
        let count = tree.count
        guard count > 0 else { return [] }
        
        // Calculate cutoff timestamp: current time minus minAgeMonths * 30 days
        let cutoffSeconds = Date().addingTimeInterval(-Double(config.minAgeMonths) * 30.0 * 86400.0).timeIntervalSince1970
        let cutoffMtime = UInt32(max(0, cutoffSeconds))
        
        var matches: [NodeRef] = []
        let rawEntries = tree.entriesRaw
        
        for i in 0..<rawEntries.count {
            let e = rawEntries[i]
            // Must be regular file
            if e.kind == EntryKind.file.rawValue {
                if e.size >= config.minSizeBytes && e.mtime <= cutoffMtime {
                    matches.append(NodeRef(index: UInt32(i), tree: tree))
                }
            }
        }
        
        return matches.sorted { $0.size > $1.size }
    }
}
